# Web cells: `#%% web` parse/serialize round-trip, the `@web` skin's per-section `{{ }}` interpolation
# and escaping (HTML entity / CSS token / JS JSON-literal), and the reactive-deps + staleness model
# (interpolating-markdown semantics, but always needs one eval).
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine
const RE = ReportEngine

findcell(r, id) = r.cells[findfirst(c -> c.id == id, r.cells)]

# Evaluate a `@web(...)` skin (built from panes) in a fresh standalone namespace with the given
# variable bindings, returning the resulting WebPage.
function eval_web(vars::NamedTuple; html = "", css = "", js = "")
    m = Module(:WebEvalT)
    RE.standalone!(m; dir = ".")
    for (k, v) in pairs(vars); Core.eval(m, :(const $(k) = $(v))); end
    return Core.eval(m, Base.Meta.parse(RE._web_skin(; html = html, css = css, js = js)))
end

@testset "Web cells" begin

    @testset "parse: #%% web kind + verbatim source" begin
        src = """
        #%% web id=hero
        @web(html\"\"\"
        <h1>hi</h1>
        \"\"\")
        """
        r = parse_report(src)
        @test length(r.cells) == 1
        @test r.cells[1].kind == WEB
        @test r.cells[1].id == "hero"
        # A web cell's source is stored verbatim (the runnable @web skin) — no unwrapping, unlike md.
        @test occursin("@web(html", r.cells[1].source)
        @test RE._kind_token(WEB) == "web"
    end

    @testset "serialize round-trips source + kind" begin
        r = parse_report("#%% web id=w\n" * RE._web_skin(html = "<b>{{ x }}</b>", js = "const n = {{ x }};"))
        c = r.cells[1]
        r2 = parse_report(serialize_report(r))
        @test r2.cells[1].kind == WEB
        @test r2.cells[1].id == c.id
        @test r2.cells[1].source == c.source          # exact text round-trip
    end

    @testset "_slate_json: primitives + <script> safety" begin
        @test RE._slate_json(42) == "42"
        @test RE._slate_json(3.5) == "3.5"
        @test RE._slate_json(true) == "true"
        @test RE._slate_json(nothing) == "null"
        @test RE._slate_json(NaN) == "null"           # NaN/Inf aren't valid JSON
        @test RE._slate_json("hi") == "\"hi\""
        @test RE._slate_json([1, 2, 3]) == "[1,2,3]"
        @test RE._slate_json((a = 1, b = "x")) == "{\"a\":1,\"b\":\"x\"}"
        @test RE._slate_json(Dict("k" => false)) == "{\"k\":false}"
        # `<`/`>` are unicode-escaped so a value can never spell `</script>` and break out of a <script>.
        j = RE._slate_json("</script>")
        @test !occursin("</script>", j)
        @test occursin("\\u003c", j)
    end

    @testset "per-section escapers" begin
        @test RE._web_esc_html("a & <b>") == "a &amp; &lt;b&gt;"
        @test RE._web_esc_js([1, 2, 3]) == "[1,2,3]"
        @test RE._web_esc_css(12) == "12"
        @test !occursin("}", RE._web_esc_css("red} body{display:none"))   # can't close the rule
    end

    @testset "@web interpolation, escaped per section" begin
        wp = eval_web((title = "Fish & <chips>", accent = "tomato", xs = [1, 2, 3]);
                      html = "<h1>{{ title }}</h1>",
                      css  = "#hero { color: {{ accent }}; }",
                      js   = "const pts = {{ xs }};")
        @test wp isa RE.WebPage
        @test occursin("<h1>Fish &amp; &lt;chips&gt;</h1>", wp.html)   # HTML entity-escaped
        @test occursin("color: tomato;", wp.css)                      # CSS token
        @test occursin("const pts = [1,2,3];", wp.js)                 # JS JSON literal
    end

    @testset "JS \$ and \${} stay literal; only {{ }} interpolates" begin
        wp = eval_web((n = 7,); js = raw"const el = $('#x'); const s = `${v}`; const n = {{ n }};")
        @test occursin(raw"$('#x')", wp.js)      # jQuery $ untouched
        @test occursin(raw"`${v}`", wp.js)       # template literal untouched
        @test occursin("const n = 7;", wp.js)    # {{ }} did interpolate
    end

    @testset "JS-section injection is contained" begin
        wp = eval_web((evil = "</script><img src=x onerror=alert(1)>",); js = "const t = {{ evil }};")
        @test !occursin("</script>", wp.js)      # escaped — can't break out of the <script>
    end

    @testset "JS wrapped in async IIFE receiving `root`" begin
        wp = eval_web((n = 1,); js = "root.textContent = {{ n }};")
        @test occursin("async function(root)", wp.js)         # own scope + top-level await
        @test occursin("document.currentScript", wp.js)       # root = the cell's output element
        @test occursin(".catch(", wp.js)                      # rejections surfaced, not swallowed
        @test occursin("web-err", wp.js)                      # a runtime error renders ONTO the cell
    end

    @testset "_web_sections / _web_interp_exprs" begin
        src = RE._web_skin(html = "<h1>{{ headline }}</h1>", js = "const n = {{ count }};")
        s = RE._web_sections(src)
        @test s.html == "<h1>{{ headline }}</h1>"      # exact (no dedent, one leading/trailing \n stripped)
        @test s.js == "const n = {{ count }};"
        @test isempty(s.css)
        # Panes must reassemble to the EXACT stored source — else the editor reads as spuriously "edited".
        @test RE._web_skin(html = s.html, css = s.css, js = s.js) == src
        @test Set(RE._web_interp_exprs(src)) == Set(["headline", "count"])
        # A multi-line section with interior indentation survives verbatim (no dedent drift).
        multi = RE._web_skin(html = "<div>\n  <b>{{ x }}</b>\n</div>", js = "let a = {{ y }};")
        @test RE._web_skin(; RE._web_sections(multi)...) == multi
    end

    @testset "reactive deps + staleness (interpolating-md semantics, always evals)" begin
        r = parse_report("#%% code id=src\ncount = 5\n\n#%% web id=w\n" *
                         RE._web_skin(js = "const n = {{ count }};"))
        build_dependencies!(r)
        w = findcell(r, "w")
        @test w.kind == WEB
        @test :count in w.reads          # reads the interpolated var
        @test isempty(w.writes)          # a web cell defines nothing
        @test "src" in w.deps            # depends on the writer of `count`
        @test w.state == STALE           # never auto-FRESH: must evaluate @web to render

        # A web cell with NO interpolation still must run (unlike static markdown, which goes FRESH).
        r2 = parse_report("#%% web id=static\n" * RE._web_skin(html = "<p>hello</p>"))
        build_dependencies!(r2)
        @test findcell(r2, "static").state == STALE
    end

end
