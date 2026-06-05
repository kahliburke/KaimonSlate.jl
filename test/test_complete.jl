# Cell-local completion: the binding extractor that augments REPLCompletions with
# identifiers a cell binds before it has run. Loads the package (NotebookServer
# needs HTTP/JSON), so it runs under `Pkg.test`.
using Test
using KaimonSlate
import REPL
const NS = KaimonSlate.NotebookServer

# Insert-text for a LaTeX/emoji completion of `s` (mirrors the /complete path):
# the unique symbol when `s` is an exact sequence, else the candidate names.
function _latex(s)
    comps, _, _ = REPL.REPLCompletions.completions(s, lastindex(s), Main)
    filter(!isempty, String[NS._comp_text(c) for c in comps])
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
end
