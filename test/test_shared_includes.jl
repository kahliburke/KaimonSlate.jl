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
