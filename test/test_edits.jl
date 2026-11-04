# An edit applied incrementally must leave every cell showing what a fresh run of the edited
# notebook shows. Each case is a notebook plus one edit; the oracle runs the original, applies the
# edit the way the server does (`update_source!`, then drain), and compares every cell's output with
# a fresh run of the edited source.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine
const RE = ReportEngine

_nbsrc(cells) = join(("#%% code id=$id\n$src\n" for (id, src) in cells), "")

function _edited(cells, edit)
    out = Pair{String,String}[]
    for (id, src) in cells
        k = findfirst(e -> e.first == id, edit)
        k === nothing ? push!(out, id => src) : (edit[k].second === nothing || push!(out, id => edit[k].second))
    end
    return out
end

function _drain!(r)
    for _ in 1:6
        any(c -> c.kind == RE.CODE && c.state == RE.STALE, r.cells) || break
        eval_stale!(r)
    end
    return r
end

function _shown(c, rid)
    o = c.output
    o === nothing && return "<no output>"
    s = string(o.value_repr, "|", strip(o.stdout), "|", o.exception === nothing ? "" : first(split(o.exception, '\n')))
    return replace(s, "Report_$rid" => "NB")
end

const _RUN = Ref(0)
# The cells whose incremental result differs from a fresh run, as "id: got ≠ want" strings. Each step
# is an edit (`id => source`, `id => nothing` to delete) or a whole replacement cell list; steps apply
# in order, and the fresh run is of the final notebook.
function steps_mismatches(cells, steps...)
    _RUN[] += 1
    inc, fresh = "edinc$(_RUN[])", "edfresh$(_RUN[])"
    r = parse_report(_nbsrc(cells); id = inc); build_dependencies!(r); _drain!(r)
    new = cells
    for st in steps
        new = st isa AbstractVector ? st : _edited(new, Pair{String,Union{String,Nothing}}[st])
        update_source!(r, _nbsrc(new)); _drain!(r)
    end
    f = parse_report(_nbsrc(new); id = fresh); build_dependencies!(f); _drain!(f)
    want = Dict(c.id => _shown(c, fresh) for c in f.cells)
    return ["$(c.id): $(repr(_shown(c, inc))) ≠ $(repr(want[c.id]))"
            for c in r.cells if haskey(want, c.id) && _shown(c, inc) != want[c.id]]
end

# `name => (cells, edit)`; a case passes when no cell differs from the fresh run.
edit_mismatches(cells, edit) = steps_mismatches(cells, edit)
failing(cases) = [string(name, " → ", join(m, "; ")) for (name, (cells, steps)) in cases
                  for m in (steps isa Tuple ? steps_mismatches(cells, steps...) : edit_mismatches(cells, steps),)
                  if !isempty(m)]

@testset "edits match a fresh run" begin
    @testset "a macro cell's edit reaches its readers" begin
        # The expansion that recovers a macro's writes is keyed by the new source, so the edit restales
        # through a graph that doesn't have those writes yet; the rebuild after expansion must restale
        # the readers it newly reaches.
        cases = [
            "kwdef struct" => (["S" => "Base.@kwdef struct Cfg; a::Int = 1; end", "C" => "c = Cfg().a"],
                               "S" => "Base.@kwdef struct Cfg; a::Int = 4; end"),
            "enum" => (["E" => "@enum Color red green blue", "C" => "n = length(instances(Color))"],
                       "E" => "@enum Color red green blue cyan"),
            "notebook macro defines a global" =>
                (["M" => "macro mkglob(n, v) esc(:(\$n = \$v)) end", "U" => "@mkglob qq 1", "C" => "z = qq + 1"],
                 "U" => "@mkglob qq 5"),
            "macro hides a read" =>
                (["M" => "macro getk() esc(:KK) end", "K" => "KK = 1", "U" => "y = @getk()"],
                 "K" => "KK = 2"),
        ]
        @test isempty(failing(cases))
    end

    @testset "an in-place update re-applies to a fresh value" begin
        # Re-running a mutator on its own stacks its change on the result of its last run; the cell the
        # value comes from has to run first.
        cases = [
            "bang mutation edited" => (["V" => "cv = [1]", "P" => "push!(cv, 2); nothing", "R" => "n = length(cv)"],
                                       "P" => "push!(cv, 2, 3); nothing"),
            "accumulator edited" => (["A" => "acc = 0", "B" => "acc += 1", "C" => "y = acc"],
                                     "B" => "acc += 2"),
            "rebinding update edited" => (["A" => "xs = [3, 1, 2]", "B" => "xs = vcat(xs, 0)", "C" => "n = length(xs)"],
                                          "B" => "xs = vcat(xs, 0, 0)"),
            "definer edited above a mutator" => (["V" => "dv = [1]", "P" => "push!(dv, 2); nothing", "R" => "n = length(dv)"],
                                                 "V" => "dv = [1, 1]"),
        ]
        @test isempty(failing(cases))
    end

    @testset "mutation forms the scan recognises" begin
        cases = [
            "qualified bang call" => (["V" => "dd = Dict(1 => 1)", "W" => "Base.setindex!(dd, 9, 9); nothing", "R" => "n = length(dd)"],
                                      "W" => "Base.setindex!(dd, 9, 9); Base.setindex!(dd, 10, 10); nothing"),
            "broadcast update" => (["V" => "vv = [1.0, 2.0]", "C" => "vv .*= 2; nothing", "R" => "t = sum(vv)"],
                                   "C" => "vv .*= 3; nothing"),
            "updating a Ref" => (["R0" => "ctr = Ref(0)", "C" => "ctr[] += 1; nothing", "R" => "c = ctr[]"],
                                 "C" => "ctr[] += 2; nothing"),
            "updating a field" => (["S" => "mutable struct Box; v::Int; end", "B" => "bx = Box(1)", "C" => "bx.v += 1; nothing", "R" => "r = bx.v"],
                                   "C" => "bx.v += 5; nothing"),
        ]
        @test isempty(failing(cases))
    end

    @testset "the scan's verdicts" begin
        m(src) = (w = Set{Symbol}(); r = Set{Symbol}(); RE._collect_mutations!(w, r, Meta.parse(src)); w)
        @test m("Base.setindex!(d, 1, 2)") == Set([:d])
        @test m("v .*= 2") == Set([:v])
        @test m("c[] += 1") == Set([:c])
        @test m("b.v -= 1") == Set([:b])
        @test isempty(m("s += 1"))           # rebinding, not mutation
        @test isempty(m("a == b"))
        @test isempty(m("x <= y"))
        @test isempty(m("!x"))               # negation is not a bang call
    end

    @testset "a removed definition leaves the namespace" begin
        # The namespace keeps a deleted cell's globals and methods unless they're taken back: the
        # reader of a deleted definition must fail the way a fresh run does.
        cases = [
            "deleted definer" => (["A" => "q = 41", "B" => "z = q + 1"], "A" => nothing),
            "renamed definer" => (["A" => "q = 41", "B" => "z = q + 1"], "A" => "q2 = 41"),
            "deleted function" => (["F" => "gf() = 1", "C" => "y = gf()"], "F" => nothing),
            "one method of several deleted" =>
                (["F1" => "fm(x::Int) = 1", "F2" => "fm(x::Float64) = 2", "C" => "y = fm(1)"], "F1" => nothing),
            "signature widened" => (["F" => "sg(x::Int) = 1", "C" => "y = sg(1)"], "F" => "sg(x::Integer) = 2"),
            "function used inside another function" =>
                (["F" => "inner() = 5", "G" => "outer() = inner() + 1", "C" => "y = outer()"], "F" => nothing),
            "macro deleted" =>
                (["M" => "macro two() 2 end", "U" => "y = @two()"], "M" => nothing),
            "deleted, then the delete undone" =>
                (["F" => "gf() = 1", "C" => "y = gf()"], ("F" => nothing, ["F" => "gf() = 1", "C" => "y = gf()"])),
            "cell renamed, source unchanged" =>
                (["F" => "gf() = 1", "C" => "y = gf()"], (["F2" => "gf() = 1", "C" => "y = gf()"],)),
        ]
        @test isempty(failing(cases))
    end

    @testset "what a cell defines" begin
        names(src) = sort!(collect(RE._definition_names(src)))
        @test names("f(x) = 1\nfunction g(); end\nstruct S; a; end\nabstract type A end") == [:A, :S, :f, :g]
        @test names("\"doc\"\nh(x) = x\n@inline k(x) = x\nmacro m() end\nlam = x -> x + 1") == [Symbol("@m"), :h, :k, :lam]
        @test names("const N = 3\nconst M = size(data, 1)\ny = compute(1)") == [:N]
        @test names("Base.show(io::IO, x::S) = print(io, 1)") == Symbol[]      # extends, binds nothing
        paths = RE._defined_function_paths("f(x) = 1\nBase.show(io::IO, x::S) = 1\nmacro m() end\nstruct T; end")
        @test paths == Any[:f, :(Base.show), Symbol("@m")]                    # constructors left out
    end
end
