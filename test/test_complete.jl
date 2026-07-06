# Cell-local completion: the binding extractor that augments REPLCompletions with
# identifiers a cell binds before it has run. Loads the package (NotebookServer
# needs HTTP/JSON), so it runs under `Pkg.test`.
using ReTest
using KaimonSlate
import REPL
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine   # completion.jl (`_comp_text`/`slate_completions`) is shared engine+worker → it lives here

# Insert-text for a LaTeX/emoji completion of `s` (mirrors the /complete path):
# the unique symbol when `s` is an exact sequence, else the candidate names.
function _latex(s)
    comps, _, _ = REPL.REPLCompletions.completions(s, lastindex(s), Main)
    filter(!isempty, String[RE._comp_text(c) for c in comps])
end

@testset "cell-local completion" begin
    L(code) = sort(String[String(s) for s in NS._cell_locals(code)])

    @testset "binding forms" begin
        @test "data" in L("data = load()\nresult = 1")
        @test issubset(["acc", "i"], L("acc = 0\nfor i in 1:10\n  acc += i\nend"))
        @test "f" in L("function f(x, y)\n  x + y\nend")
        @test issubset(["f", "x", "y"], L("f(x, y) = x + y"))
        @test issubset(["w", "z"], L("z = [w for w in 1:3]"))
        @test "a" in L("let a = 1\n  a\nend")
        @test issubset(["p", "q"], L("(p, q) = (1, 2)"))     # tuple destructuring
    end

    @testset "robust to the line being typed" begin
        # An incomplete trailing statement must not lose earlier bindings.
        @test "data" in L("data = 1\nresult = process(da")
        @test isempty(L("process(da"))                       # nothing complete yet
    end

    @testset "identifier prefix + field-access detection" begin
        @test NS._id_prefix("foob", 4) == (0, "foob", false)
        @test NS._id_prefix("foo.ba", 6) == (4, "ba", true)  # after a dot ⇒ field access
        @test NS._id_prefix("x = ab", 6) == (4, "ab", false)
    end

    @testset "LaTeX / unicode completion (\\pi → π)" begin
        # completion_text throws on BslashCompletion (Julia ≥1.12); _comp_text must
        # still yield the symbol — else `\pi` completes to nothing.
        @test _latex("\\pi") == ["π"]
        @test _latex("\\alpha") == ["α"]
        @test _latex("\\sqrt") == ["√"]
        @test _latex("x\\_2") == ["₂"]            # subscript
        # Partial prefix offers the names to extend to (REPL two-step behaviour).
        @test "\\alpha" in _latex("\\al")
    end

    # Favor the reader's own names over library symbols. slate_completions tags a DATA variable
    # owned by the namespace "notebook"; a function (user or injected) and imported names are left
    # general — so injected Slate helpers don't get promoted.
    @testset "favor the reader's own variables (kind tagging)" begin
        m = Module(:CompFavor)
        Core.eval(m, :(results = [1, 2, 3]))     # a data variable → owned → "notebook"
        Core.eval(m, :(myproc(x) = x))           # a function → owned but NOT promoted (stays general)
        k(mod, code) = Dict(RE.slate_completions(mod, code, lastindex(code)).items)
        kr = k(m, "res")
        @test get(kr, "results", "") == "notebook"          # the reader's variable is promoted
        @test "reshape" in keys(kr) && get(kr, "reshape", "") != "notebook"   # Base name stays general
        @test get(k(m, "myproc"), "myproc", "") == "function"   # a function isn't promoted (keeps helpers out)
    end

    # The popup order: current-cell binding first, then other-cell notebook variable, then the
    # library names — the three tiers the ranker enforces.
    @testset "three-tier completion ranking" begin
        items = Tuple{String,String}[("reshape", "function"), ("results", "notebook"),
                                     ("resA", "local"), ("Result", "type")]
        ranked = first.(NS._rank_completions(items, "res"))
        @test ranked[1] == "resA"                            # current-cell local, tier 0
        @test ranked[2] == "results"                         # other-cell notebook variable, tier 1
        @test findfirst(==("reshape"), ranked) > 2           # general library names sink below both
    end
end

@testset "output image externalization" begin
    import Base64
    # A real PNG header (8-byte sig + IHDR with width=640, height=480) so _png_dims reads dimensions.
    pngbytes = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
                     0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
                     0x00, 0x00, 0x02, 0x80, 0x00, 0x00, 0x01, 0xe0]   # 640 × 480
    png = Base64.base64encode(pngbytes)
    html = "<div class=\"disp img\"><img alt=\"output\" src=\"data:image/png;base64,$png\"/></div>"
    out = NS._externalize_blobs("nbX", html)
    @test occursin("/api/nbX/blob/", out)          # data-URI replaced with a cached blob URL
    @test !occursin("data:image", out)
    @test occursin("width=\"640\"", out) && occursin("height=\"480\"", out)   # dims reserved → no layout shift
    m = match(r"/api/nbX/blob/([0-9a-f]+)", out)
    @test m !== nothing
    b = NS.blob_get("nbX/" * m.captures[1])
    @test b !== nothing && b[1] == "image/png" && b[2] == pngbytes
    @test NS._png_dims(pngbytes) == (640, 480)
    @test NS._externalize_blobs("", html) == html   # empty nbid → unchanged (export path keeps inline base64)
    @test NS._externalize_blobs("nbX", "<p>no images</p>") == "<p>no images</p>"
end
