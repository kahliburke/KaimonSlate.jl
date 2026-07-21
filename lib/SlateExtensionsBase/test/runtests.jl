using SlateExtensionsBase
using Test

# Top-level (structs and methods can't be defined in a @testset's local scope): a custom type
# that opts into @bind by overloading to_widget — the typed-constructor extension path.
struct Knob; lo::Int; hi::Int; end
SlateExtensionsBase.to_widget(k::Knob) = Widget("knob", k.lo; min = k.lo, max = k.hi)

@testset "SlateExtensionsBase" begin

    @testset "Widget construction" begin
        w = Widget("slider", Dict{String,Any}("min" => 0, "max" => 10), 5)
        @test w.kind == "slider"
        @test w.default == 5
        @test w.params["max"] == 10
        # keyword convenience form
        w2 = Widget("mathfield", "x"; label = "answer", rows = 3)
        @test w2.kind == "mathfield"
        @test w2.default == "x"
        @test w2.params == Dict{String,Any}("label" => "answer", "rows" => 3)
        @test Widget("empty").default == ""      # default default
    end

    @testset "to_widget interface" begin
        w = Widget("x", 1)
        @test to_widget(w) === w                 # identity on a Widget
        tw = to_widget(Knob(2, 9))
        @test tw.kind == "knob" && tw.default == 2 && tw.params["max"] == 9
        @test_throws ArgumentError to_widget(3.0)   # a plain value with no method
    end

    @testset "Choice value semantics" begin
        c = Choice(:a, "Apple", 2)
        @test c.value === :a && c.v === :a
        @test c.label == "Apple" && c.l == "Apple"
        @test c.index == 2 && c.i == 2
        @test c == :a && :a == c                 # compares as its value
        @test string(c) == "a" && "$(c)" == "a"  # prints/interpolates as its value
        @test hash(c) == hash(:a)                 # hashes as its value
        @test Dict(:a => 10)[c] == 10             # usable as a dict key
        # scalar convert/index transparency
        cn = Choice(3, "three")
        @test convert(Int, cn) === 3
        @test Int(cn) === 3
        @test [10, 20, 30][cn] == 30              # to_index
        @test propertynames(c) == (:value, :label, :index, :v, :l, :i)
    end

    @testset "Selection" begin
        sel = Selection(Choice[Choice(:a, "A", 1), Choice(:c, "C", 3)])
        @test length(sel) == 2
        @test collect(keys(sel)) == [:a, :c]
        @test collect(values(sel)) == ["A", "C"]
        @test sel[:a] == "A"
        @test haskey(sel, :c) && !haskey(sel, :b)
        @test indices(sel) == [1, 3]
        @test_throws KeyError sel[:z]
    end

    @testset "register_kind! lifecycle + defaults" begin
        # Unregistered kind → pass-through coerce, keep-across-rerun reconcile, identity wrap.
        u = Widget("unknown_kind_xyz", "d")
        @test coerce_bind(u, "hi") == "hi"
        @test wrap_value(u, "hi") == "hi"
        @test reconcile_bind(u, "kept", Widget("unknown_kind_xyz", "d2")) == "kept"       # same kind → keep
        @test reconcile_bind(Widget("other", 1), "old", u) == "d"                          # kind changed → new default

        # A registered kind exercises all three hooks.
        register_kind!("rating";
            coerce = (w, v) -> clamp(round(Int, v isa Number ? v : parse(Float64, string(v))), 0, 5),
            reconcile = (ow, ov, nw) -> ov isa Integer && 0 <= ov <= 5 ? ov : nw.default,
            wrap = (w, v) -> (stars = v, of = 5))
        r = Widget("rating", 3)
        @test coerce_bind(r, 7.2) == 5           # clamped + rounded
        @test coerce_bind(r, "2") == 2
        @test wrap_value(r, 4) == (stars = 4, of = 5)
        @test reconcile_bind(r, 4, Widget("rating", 0)) == 4      # in range → kept
        @test reconcile_bind(r, 99, Widget("rating", 0)) == 0     # out of range → default
        @test "rating" in widget_kinds()
    end

    @testset "WebPage rendering" begin
        html(w) = sprint(show, MIME"text/html"(), w)
        @test html(WebPage(html = "<b>hi</b>")) == "<b>hi</b>"
        s = html(WebPage(css = "a{}", html = "<p>", js = "x=1"))
        @test occursin("<style>a{}</style>", s)
        @test occursin("<p>", s)
        @test occursin("<script>x=1</script>", s)
        # empty sections omitted
        @test !occursin("<style>", html(WebPage(html = "x")))
        @test !occursin("<script>", html(WebPage(html = "x")))
        # </script> / </style> in content can't break out: the JS's own </script> is escaped,
        # leaving exactly one real closing tag (the wrapper's).
        sj = html(WebPage(js = "a</script>b"))
        @test occursin("a<\\/script>b", sj)                 # content tag escaped
        @test length(findall("</script>", sj)) == 1         # only the wrapper's closing tag remains
        # obscure packs the JS
        @test occursin("atob(", html(WebPage(js = "secret()", obscure = true)))
        @test !occursin("secret()", html(WebPage(js = "secret()", obscure = true)))
    end

    @testset "register_widget_js" begin
        wp = register_widget_js("mathfield", "window.slateRegisterWidget('mathfield', {})")
        @test wp isa WebPage
        s = sprint(show, MIME"text/html"(), wp)
        @test occursin("slateRegisterWidget('mathfield'", s)
        @test startswith(s, "<script>")
    end

    @testset "execution context (task-local convention)" begin
        # No context outside a cell.
        @test slate_context() === nothing
        @test slate_region() === nothing
        @test slate_regions() == Symbol[]
        @test slate_side() == "" && slate_notebook() == ""
        @test slate_emit("ch", (a = 1,)) === nothing        # no-op, no throw
        @test slate_everywhere(:op) === nothing

        # Seed a fake context (a NamedTuple, exactly as the engine builds it) and read it back.
        emitted = Tuple{Any,Any}[]
        effects = Tuple{Symbol,Vector{Symbol}}[]
        ctx = (region = :gpu, side = "gpu", regions = [:gpu, :cpu], notebook = "nb1",
               emit = (ch, v) -> push!(emitted, (ch, v)),
               effect = (kind; names = Symbol[], data...) -> push!(effects, (kind, collect(names))))
        task_local_storage(:slate_ctx, ctx)
        try
            @test slate_region() === :gpu
            @test slate_side() == "gpu"
            @test slate_regions() == [:gpu, :cpu]
            @test slate_notebook() == "nb1"
            slate_emit("net", (loss = 0.5,))
            @test emitted == [("net", (loss = 0.5,))]
            slate_everywhere(:my_op, :my_rule)
            @test effects == [(:everywhere, [:my_op, :my_rule])]
        finally
            delete!(task_local_storage(), :slate_ctx)
        end
        @test slate_context() === nothing        # cleaned up

        # Dict-shaped context is tolerated too (string or symbol keys).
        task_local_storage(:slate_ctx, Dict("region" => "cpu", "notebook" => "nb2"))
        try
            @test slate_region() == "cpu"        # raw field value; _ctx_field doesn't Symbol-coerce region
            @test slate_notebook() == "nb2"
        finally
            delete!(task_local_storage(), :slate_ctx)
        end
    end

end
