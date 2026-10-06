# A file included into TWO modules must not name a package only one of them has.
#
# `engine.jl` (module `ReportEngine`, the in-process kernel) and `worker.jl` (module `SlateWorker`,
# the gate worker) share seventeen `include`s. An `import` written at the top of one of them does
# nothing for the other, so a shared file that says `Foo.bar()` compiles fine in both and throws
# `UndefVarError` in whichever module lacks `Foo` — at CALL time, in whatever cell reached it.
#
# That is issue #34: `bind_observable` named `Observables`, only the engine imported it, and the
# function worked in standalone Slate and threw on the worker. Nothing caught it, because the
# feature's own tests build their namespace with `standalone!` — the in-process path, the module
# where it worked. The gap was never in the tested code, it was in which module ran it.
#
# Checked over the PARSED file rather than its text: an earlier grep for this flagged four hits and
# three were prose in a comment or a `JSON.parse` inside a JavaScript string.
using ReTest

const _SRC = joinpath(@__DIR__, "..", "src")

# `import A, B` / `using A` / `@eval import A`, wherever they appear in the file.
function _imported_packages(path::AbstractString)
    out = Set{Symbol}()
    walk(x) = x isa Expr && (
        (x.head in (:import, :using) && for a in x.args
            a isa Expr && a.head === :. && !isempty(a.args) && a.args[1] isa Symbol &&
                push!(out, a.args[1])
        end);
        foreach(walk, x.args))
    walk(Meta.parseall(read(path, String)))
    return out
end

# Module-qualified references — the `Foo` in `Foo.bar`. Only in code: the parser has already
# dropped comments, and a string is a literal rather than an `Expr(:.)`.
function _qualified_by(path::AbstractString)
    out = Set{Symbol}()
    walk(x) = x isa Expr && (
        (x.head === :. && length(x.args) == 2 && x.args[1] isa Symbol &&
            isuppercase(first(string(x.args[1]))) && push!(out, x.args[1]));
        foreach(walk, x.args))
    walk(Meta.parseall(read(path, String)))
    return out
end

_includes(path) = Set(m.captures[1] for m in
    eachmatch(r"include\(joinpath\(@__DIR__, \"([^\"]+)\"\)\)", read(path, String)))

@testset "a shared include names no package only one module has" begin
    engine, worker = joinpath(_SRC, "engine.jl"), joinpath(_SRC, "worker.jl")
    shared = sort(collect(intersect(_includes(engine), _includes(worker))))
    @test length(shared) > 10            # the sets resolved; a typo'd path would empty this

    E, W = _imported_packages(engine), _imported_packages(worker)
    skewed = symdiff(E, W)               # imported by exactly one of the two
    @test !isempty(skewed)               # ...there are always some; this is not vacuous

    bad = String[]
    for f in shared
        path = joinpath(_SRC, f)
        own = _imported_packages(path)   # a shared file may import for itself — widgets.jl does
        for p in intersect(_qualified_by(path), skewed)
            p in own && continue
            where = p in E ? "engine.jl" : "worker.jl"
            push!(bad, "$f names `$p.…` but only $where imports it — it will throw UndefVarError " *
                       "in the other module. Import it in BOTH, or in $f itself.")
        end
    end
    @test isempty(bad) || (println(join(bad, "\n")); false)

    # The instance that got away (#34), pinned as the arrangement rather than the symptom:
    # NEITHER module imports Observables. widgets.jl resolves it for itself, by UUID and allowed to
    # fail, because the worker's LOAD_PATH is the notebook's env plus the slate infra env — Slate's
    # own environment is not on it, so an import there takes worker startup down when it misses.
    w = joinpath(_SRC, "widgets.jl")
    @test !(:Observables in _imported_packages(engine))
    @test !(:Observables in _imported_packages(worker))
    @test !(:Observables in _imported_packages(w))
    # By UUID rather than name: `import` sees only DIRECT dependencies, and a notebook with Makie
    # has Observables in its manifest without naming it.
    @test occursin("510215fc-4207-5dde-b226-833fc4488ee2", read(w, String))
end

# The worker is a package, and a package can only import what its Project.toml declares: an import
# missing from `[deps]` fails the image build, and a host whose env lacks it never boots a worker.
# Imports evaluated into `Main` are excluded, since they resolve from the notebook's env.
@testset "the worker package declares exactly what the worker imports" begin
    import TOML
    function own_imports(path)
        out = Set{Symbol}()
        walk(x) = x isa Expr && begin
            # `@eval Main using X` / `@eval(Main, import X)` load into Main, not the worker
            x.head === :macrocall && x.args[1] === Symbol("@eval") && any(==(:Main), x.args) && return
            if x.head in (:import, :using)
                for a in x.args
                    b = a isa Expr && a.head === :(:) ? a.args[1] : a
                    b isa Expr && b.head === :. && !isempty(b.args) && b.args[1] isa Symbol &&
                        b.args[1] !== :. && push!(out, b.args[1])
                end
            end
            foreach(walk, x.args)
        end
        walk(Meta.parseall(read(path, String)))
        return out
    end
    have = Set(filter(f -> endswith(f, ".jl"), readdir(_SRC)))
    seen, todo = Set{String}(), ["worker.jl"]
    while !isempty(todo)
        f = pop!(todo)
        (f in seen || !(f in have)) && continue
        push!(seen, f)
        for m in eachmatch(r"\"([A-Za-z0-9_]+\.jl)\"", read(joinpath(_SRC, f), String))
            push!(todo, m.captures[1])
        end
    end
    imports = setdiff(reduce(union, (own_imports(joinpath(_SRC, f)) for f in seen)), [:Base, :Core])
    pkg = joinpath(_SRC, "SlateWorker")
    deps = Set(Symbol.(keys(TOML.parsefile(joinpath(pkg, "Project.toml"))["deps"])))
    @test setdiff(imports, deps) == Set{Symbol}()   # imported, not declared: the image build fails
    @test setdiff(deps, imports) == Set{Symbol}()   # declared, not imported: a resolve for nothing
    @test occursin("worker.jl", read(joinpath(pkg, "src", "SlateWorker.jl"), String))
end
