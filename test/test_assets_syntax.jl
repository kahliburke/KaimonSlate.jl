# Every shipped front-end script must PARSE.
#
# This exists because a stray backtick inside a comment in `extensions.js`'s CSS block — which is a
# template literal — terminated the string, so the rest of the stylesheet was parsed as JavaScript
# and the whole module failed to load. Nothing in the suite noticed: the Julia tests don't execute
# the front-end, and the browser only reports it once a user opens the page.
#
# A parse check is cheap and catches that entire class (unbalanced backticks, quotes, braces) at the
# only point where it's still free to fix. It does NOT run the code or check behaviour.
using ReTest

const JSDIR = normpath(joinpath(@__DIR__, "..", "src", "assets", "js"))

# Generated/vendored bundles aren't ours to fix and are slow to parse; everything else is.
const SKIP = ("cm6.bundle.js",)

"""
    parses(node, path) -> (ok, output)

Does `path` parse, as the kind of script it actually is?

`src/assets/js` holds both classic scripts and ES modules, so the kind is decided from the source
(a top-level `import`/`export` means a module) and checked as ONLY that kind. Accepting "parses as
either" instead looks safer and is useless: node's sloppy-mode check waved through the very
template-literal breakage this file exists to catch, because it only failed under module rules.
"""
function parses(node, path)
    src = read(path, String)
    esm = occursin(r"^\s*(import|export)\s"m, src)
    tmp = joinpath(mktempdir(), "check" * (esm ? ".mjs" : ".js"))
    cp(path, tmp; force = true)
    io = IOBuffer()
    ok = success(pipeline(`$node --check $tmp`; stdout = io, stderr = io))
    return (ok, String(take!(io)))
end

@testset "front-end assets parse" begin
    node = Sys.which("node")
    if node === nothing
        @info "node not found — skipping the front-end parse check"
        @test true
    else
        files = sort!(filter(f -> endswith(f, ".js") && f ∉ SKIP, readdir(JSDIR)))
        @test !isempty(files)
        # One assertion over the whole set, naming the offenders and printing node's message — a
        # per-file @test in a loop would bury which file broke in a wall of passes.
        bad = String[]
        for f in files
            ok, out = parses(node, joinpath(JSDIR, f))
            ok || (push!(bad, f); @error "front-end script failed to parse" file = f output = out)
        end
        @test isempty(bad)
    end
end
