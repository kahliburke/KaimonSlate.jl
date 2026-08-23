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
using KaimonSlate                       # the export-embedded constants are module state, not files

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

# The same check, for the front-end code that does NOT live in a `.js` file.
#
# A static export cannot load `src/assets/js`, so parts of the runtime are mirrored into Julia string
# constants and written straight into the page. Those strings go through Julia's own escape
# processing on the way out, which means the JavaScript that reaches a browser is not the text in the
# source file: a `\"` written to escape a quote for JS is consumed by Julia and emitted as a bare
# one. That shipped `querySelectorAll("input[type="checkbox"]")`, a SyntaxError that took the entire
# shim down — so every control on the page rendered disabled and nothing was logged anywhere.
#
# Checking the CONSTANTS (not the source text) is the point: it is the only way to see what the page
# actually gets.
@testset "export-embedded front-end constants parse" begin
    node = Sys.which("node")
    if node === nothing
        @info "node not found — skipping the export-constant parse check"
        @test true
    else
        NS = KaimonSlate.NotebookServer
        # Each is a complete script the export writes into a <script> tag of its own.
        blobs = [(name, getfield(NS, name)) for name in
                 (:_EXPORT_ASSET_JS, :_EXPORT_TABLE_JS, :_EXPORT_MEDIA_JS, :_EXPORT_ECHARTS_THEME_JS,
                  :_EXPORT_CHART_RUNTIME_JS)
                 if isdefined(NS, name)]
        @test length(blobs) == 5          # a renamed constant must fail loudly, not silently skip
        bad = String[]
        dir = mktempdir()
        for (name, src) in blobs
            src isa AbstractString || (push!(bad, "$name is not a String"); continue)
            tmp = joinpath(dir, string(name, ".js"))
            write(tmp, src)
            io = IOBuffer()
            if !success(pipeline(`$node --check $tmp`; stdout = io, stderr = io))
                push!(bad, String(name))
                @error "export-embedded script failed to parse" constant = name output = String(take!(io))
            end
        end
        @test isempty(bad)
    end
end

# The gzip path an exported page uses to unpack a `@replay` sweep: it must round-trip, and it must
# not drain the stream through `new Response(...)`. See test/js/asset_inflate.mjs for why the second
# one is a correctness requirement and not a style note.
@testset "export asset inflate (node, if available)" begin
    node = Sys.which("node")
    if node === nothing
        @info "node not found — skipping the export asset-inflate check"
        @test true
    else
        io = IOBuffer()
        script = joinpath(@__DIR__, "js", "asset_inflate.mjs")
        ok = success(pipeline(`$node $script`; stdout = io, stderr = io))
        ok || print(String(take!(io)))
        @test ok
    end
end
