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

    @testset "a cell that calls a function takes on what its body does" begin
        # A function body reads and changes globals when it's CALLED, so its effects belong to the
        # cells that call it (resolved against the writers above each caller), not the one defining it.
        cases = [
            "body reads a global defined below it" => (["A" => "f() = a + 1", "B" => "a = 1", "C" => "y = f()"], "B" => "a = 2"),
            "transitively" => (["G" => "g() = a * 10", "F" => "f() = g() + 1", "B" => "a = 1", "C" => "y = f()"], "B" => "a = 3"),
            "stored closure" => (["H" => "h = () -> a + 100", "B" => "a = 1", "C" => "y = h()"], "B" => "a = 5"),
            "keyword default" => (["F" => "kd(; k = K) = k", "B" => "K = 1", "C" => "y = kd()"], "B" => "K = 9"),
            "global assigned in the body" =>
                (["F" => "setg() = (global gg = base * 2; nothing)", "B" => "base = 1", "C" => "setg()", "R" => "r = gg + 0"],
                 "B" => "base = 4"),
            "body mutates a global" =>
                (["V" => "v = Int[]", "F" => "addone() = push!(v, 1)", "C" => "addone(); nothing", "R" => "n = length(v)"],
                 "C" => "addone(); addone(); nothing"),
            "helper mutates its argument" =>
                (["V" => "d = Dict{Int,Int}()", "W" => "put7(x) = (x[7] = 7; nothing)", "C" => "put7(d)", "R" => "ks = sort(collect(keys(d)))"],
                 "C" => "put7(d); d[8] = 8; nothing"),
            "argument mutated two calls deep" =>
                (["G" => "inner(x) = push!(x, 1)", "F" => "outer(x) = (inner(x); nothing)", "V" => "v = Int[]", "C" => "outer(v)", "R" => "n = length(v)"],
                 "C" => "outer(v); outer(v)"),
            "Ref updated in a helper" =>
                (["R0" => "counter = Ref(0)", "F" => "bump() = (counter[] += 1)", "C" => "bump(); nothing", "R" => "c = counter[]"],
                 "C" => "bump(); bump(); nothing"),
            "non-bang broadcast helper" =>
                (["V" => "vv = [1.0, 2.0]", "F" => "scale(v) = (v .*= 2; v)", "C" => "scale(vv); nothing", "R" => "t = sum(vv)"],
                 "C" => "scale(vv); scale(vv); nothing"),
            "methods split across cells" =>
                (["F" => "function fe end", "M1" => "fe(x::Int) = x + k1", "K" => "k1 = 1", "C" => "y = fe(1)"], "K" => "k1 = 7"),
            "loop accumulates into a global (soft scope)" =>
                (["A" => "s = 0", "B" => "for i in 1:3; s += i; end", "C" => "t = s"], "B" => "for i in 1:5; s += i; end"),
            "loop assigns a global in a try" =>
                (["A" => "st = 0", "B" => "for i in 1:3; try; st = i; catch; end; end", "C" => "u = st"], "B" => "for i in 1:7; try; st = i; catch; end; end"),
            "helper evals a global into the notebook" =>
                (["D" => "define!(n, v) = Core.eval(@__MODULE__, :(\$n = \$v))", "C" => "define!(:foo, 1)", "R" => "r = foo + 1"],
                 "C" => "define!(:foo, 2)"),
            "editing a helper doesn't re-run its data" =>
                (["V" => "w = [1]", "F" => "addw() = push!(w, 2)", "C" => "addw(); nothing", "R" => "n = length(w)"],
                 "F" => "addw() = push!(w, 2, 3)"),
        ]
        @test isempty(failing(cases))
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
            "locked cell deleted, then the delete undone" =>
                (["F locked" => "gf() = 1", "C" => "y = gf()"],
                 ("F locked" => nothing, ["F locked" => "gf() = 1", "C" => "y = gf()"])),
            "let-defined function widened" =>
                (["F" => "let k = 1\n    global lk(x::Int) = k\nend", "C" => "y = lk(1)"],
                 "F" => "let k = 2\n    global lk(x::Integer) = k\nend"),
            "function in a begin block deleted" =>
                (["F" => "begin\n    bf() = 1\nend", "C" => "y = bf()"], "F" => nothing),
            "definer edited away and back before anything runs" =>
                (["A" => "q = 41", "B" => "z = q + 1"], ("A" => "q2 = 41", "A" => "q = 41")),
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

    @testset "an eval cell stops being a barrier once its run is seen" begin
        cells = ["data" => "raw = collect(1:10)", "gen" => "for n in (:fa, :fb); @eval \$n(x) = x + 1; end",
                 "use" => "y = fa(1)", "other" => "z = 42"]
        r = parse_report(_nbsrc(cells); id = "evbarrier"); build_dependencies!(r)
        gen, use, other = r.cells[2], r.cells[3], r.cells[4]
        @test :eval_barrier in gen.flags
        @test "gen" in other.deps                         # before it has run, everything below waits on it
        _drain!(r)
        @test gen.observed_complete
        @test "gen" in use.deps && !("gen" in other.deps) # after: only the reader of what it bound
        @test "data" in gen.deps                          # and it still depends on everything above
        @test !isempty(RE._memo_key(r, other))            # the cells below can be cached again
        @test !isempty(RE._memo_key(r, use))
        # Editing it brings the barrier back until the new source has run.
        update_source!(r, _nbsrc([k == "gen" ? k => "for n in (:fa, :fb); @eval \$n(x) = x + 2; end" : k => v for (k, v) in cells]))
        @test "gen" in r.cells[4].deps
        # Edits around it still match a fresh run.
        cases = [
            "eval cell edited" => (cells, "gen" => "for n in (:fa, :fb); @eval \$n(x) = x + 5; end"),
            "cell above an eval cell edited" => (cells, "data" => "raw = collect(1:20)"),
            "unrelated cell below edited" => (cells, "other" => "z = 43"),
        ]
        @test isempty(failing(cases))
    end

    @testset "qualified paths a cell mentions are reads" begin
        c = RE.Cell("f", RE.CODE, "f = HotDemo.apply(HotDemo.leaf, 3)"); infer_bindings!(c)
        @test Symbol("HotDemo.leaf") in c.reads && Symbol("HotDemo.apply") in c.reads
        c2 = RE.Cell("g", RE.CODE, "y = p.x + 1"); infer_bindings!(c2)
        @test Symbol("p.x") in c2.reads && :p in c2.reads   # a field path too; it makes no edge
    end

    @testset "soft-scope assignments" begin
        soft(src) = sort!(collect(RE._soft_assigns!(Set{Symbol}(), Meta.parse(src))))
        @test soft("for i in 1:3; s += i; t = i; end") == [:s, :t]
        @test soft("for i in 1:3; local q = i; q += 1; end") == Symbol[]    # declared local
        @test soft("for (a, b) in pairs(x); a = 1; end") == Symbol[]         # loop variables
        @test soft("for i in 1:3; f = () -> (z = 1); end") == Symbol[]       # a closure is a hard scope
        @test soft("let; for i in 1:3; w = i; end; end") == Symbol[]         # inside a let: local
        @test soft("x = 1") == Symbol[]                                     # top level is not soft
    end

    @testset "what a run is seen to bind" begin
        r = parse_report("#%% code id=a\nx1 = 1\n#%% code id=b\ny1 = 2\n#%% code id=c\nz = w1 + y1\n")
        build_dependencies!(r)
        a, b, c = r.cells
        # Cells in a parallel batch share the namespace, so a's observation can contain b's `y1`: a
        # name another cell defines by the analysis is never taken as an observed write.
        @test !RE.note_defines!(r, a, [:x1, :y1])
        @test RE.note_defines!(r, a, [:w1]) && a.observed == Set([:w1])
        build_dependencies!(r)
        @test "a" in c.deps                                  # the reader of w1 now depends on a
        # A stored observation that names another cell's write is ignored at build time too.
        push!(b.observed, :x1); build_dependencies!(r)
        @test !(:x1 in b.writes)
        # A job cell's assignments count as the analysis's too: one batch can run it beside a code cell.
        rj = parse_report("#%% job id=j\nrows = [1, 2]\n#%% code id=k\nlen = 3\n")
        build_dependencies!(rj)
        @test !RE.note_defines!(rj, rj.cells[2], [:rows])
    end

    @testset "what a restore replays" begin
        plan(src) = (p = RE._replay_plan(src); (p.idx, sort!(collect(p.names))))
        # a `begin` opens no scope: its definitions are top-level definitions, its compute is not
        @test plan("begin\n  f(x) = 1\n  y = f(2)\nend") == ([1], [:f])
        # a `let` that defines a global function replays whole, with the globals it assigns
        @test plan("let k = 3\n global scaled(x) = k * x\n global kk = k\nend\nt = scaled(2)") == ([1], [:kk, :scaled])
        @test plan("let c = 1\n global h\n function h(x) x + c end\nend") == ([1], [:h])
        @test plan("g = let s = 2; x -> x * s; end") == ([1], [:g])
        @test plan("ga = function (x)\n  x + 1\nend") == ([1], [:ga])
        # a block that computes would replay to different captured values: not replayed
        @test plan("let k = rand()\n global rk(x) = k * x\nend") == (Int[], Symbol[])
        @test plan("let k = 3\n global m = fit(data)\n global mk(x) = k * x\nend") == (Int[], Symbol[])
        @test plan("g2 = let s = sum(1:3); x -> x * s; end") == (Int[], Symbol[])
        @test plan("let k = scale, ks = [1, 2], r = 1:3\n global sk(x) = k * x\nend") == ([1], [:sk])
        # a `let` that only computes is not a definition
        @test plan("let; global a = sum(1:10); end") == (Int[], Symbol[])
        @test plan("y = compute(1)\nz = y + 1") == (Int[], Symbol[])
        # a global function a `let` defines has its methods taken back on re-run
        @test RE._defined_function_paths("let k = 1\n global lk(x) = k\nend") == Any[:lk]
    end
end
