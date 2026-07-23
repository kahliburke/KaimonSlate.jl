using SlateExtensionsBase
using Test

# Top-level (structs and methods can't be defined in a @testset's local scope): a custom type
# that opts into @bind by overloading to_widget — the typed-constructor extension path.
struct Knob; lo::Int; hi::Int; end
SlateExtensionsBase.to_widget(k::Knob) = Widget("knob", k.lo; min = k.lo, max = k.hi)

# A custom VALUE type that teaches Slate how to coerce it, via one `coerce_value` dispatch method.
struct Celsius; c::Float64; end
SlateExtensionsBase.coerce_value(::Type{Celsius}, v) =
    Celsius(Float64(v isa Number ? v : parse(Float64, string(v))))

# A widget struct for `auto_widget` reflection: `default` = value; other fields = params; `note` unset → skipped.
struct Dial; lo::Int; hi::Int; default::Int; note::Union{Nothing,String}; end

# A widget type that declares its front-end lazily via `required_assets` (no __init__).
struct Gauge; default::Int; end
SlateExtensionsBase.required_assets(::Type{Gauge}) = "export default () => {}"

# A package with a PACKAGE-GLOBAL front-end hook (editor ext + a JS→Julia handler, no bind to trigger
# it): Slate calls `__slate_frontend(slate_on)`, handing it the notebook's `slate_on`. The hook registers
# both a front-end script and a handler — the inline-math/giac shape, in miniature.
module FakeExtPkg
    using SlateExtensionsBase
    function __slate_frontend(slate_on)
        provide_frontend!("EDITOR_EXT"; id = "FakeExtPkg.editor")
        slate_on("fake_channel", a -> a)
    end
end

# Rich output: a value that renders as a COMPONENT descriptor, and one via the HTML escape hatch.
struct Meter; value::Int; max::Int; end
SlateExtensionsBase.slate_render(m::Meter) = component("Demo.Meter"; value = m.value, max = m.max)
struct Banner; text::String; end
SlateExtensionsBase.slate_render(b::Banner) = html_fragment("<b>" * b.text * "</b>")

# Per-cell toolbar action: a struct that reflects into a CellAction (auto_cell_action), and one that
# omits a REQUIRED field (`onclick`) so reflection must error — mirrors the Knob/Dial widget pattern.
Base.@kwdef struct InsertBtn
    icon::String    = "➕"
    title::String   = "insert a snippet"
    show::String    = "cell.kind === 'code'"
    onclick::String = "window.myExtInsert(cellId)"
end
SlateExtensionsBase.to_cell_action(a::InsertBtn) = auto_cell_action(a)
struct NoClickBtn; icon::String; end   # no `onclick` field → auto_cell_action must throw
# Only the REQUIRED fields — `title`/`show` are absent, so reflection must default them to "".
Base.@kwdef struct MinBtn; icon::String = "•"; onclick::String = "f(cellId)"; end
SlateExtensionsBase.to_cell_action(a::MinBtn) = auto_cell_action(a)

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
        # Type-derived kind: namespaced by the defining module, so two packages can't collide.
        @test kind_for(Knob) == "Main.Knob"
        wt = Widget(Knob, 3; min = 0, max = 9)
        @test wt.kind == "Main.Knob" && wt.default == 3 && wt.params["max"] == 9
        # NamedTuple params (ergonomic authoring form) → stored as the wire Dict.
        wn = Widget("slider", (; min = 0, max = 10), 5)
        @test wn.params == Dict{String,Any}("min" => 0, "max" => 10) && wn.default == 5
    end

    @testset "auto_widget (reflect a struct)" begin
        w = auto_widget(Dial(0, 9, 3, "temp"))
        @test w.kind == "Main.Dial" && w.default == 3            # `default` field → the value slot
        @test w.params == Dict{String,Any}("lo" => 0, "hi" => 9, "note" => "temp")  # other fields → params
        @test !haskey(w.params, "default")                       # value is NOT duplicated into params
        @test !haskey(auto_widget(Dial(0, 9, 3, nothing)).params, "note")  # a `nothing` field is skipped
        @test auto_widget(Dial(0, 9, 3, "x"); exclude = (:lo,)).params == Dict{String,Any}("hi" => 9, "note" => "x")
        # value= picks a different value field; a missing value field errors clearly.
        @test auto_widget(Dial(0, 9, 3, nothing); value = :hi).default == 9
        @test_throws ArgumentError auto_widget(Knob(1, 2))       # no `default` field
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

    # Type-driven default: with NO register_kind!, Slate coerces the browser value to the type of the
    # widget's `default` (via `coerce_value`), with error-fallback — so a typed widget needs no hooks.
    @testset "type-driven coercion (coerce_value)" begin
        wi = Widget("untyped_int", 0)                 # default::Int
        @test coerce_bind(wi, 3.7) === 4              # JSON float → rounded Int
        @test coerce_bind(wi, "5") === 5             # numeric string → parsed Int
        @test coerce_bind(wi, "nope") === 0          # unparseable → error-fallback to default
        wf = Widget("untyped_float", 0.0)             # default::Float64
        @test coerce_bind(wf, 3) === 3.0
        wb = Widget("untyped_bool", false)            # default::Bool
        @test coerce_bind(wb, 1) === true && coerce_bind(wb, "true") === true
        ws = Widget("untyped_str", "")                # default::String → identity
        @test coerce_bind(ws, "hi") == "hi"
        wd = Widget("untyped_dict", Dict("a" => 1))   # non-scalar default → pass through untouched
        @test coerce_bind(wd, [1, 2]) == [1, 2]

        # Dispatch is extensible: `Celsius` (top-level) taught Slate its coercion with one method.
        wc = Widget("temp", Celsius(0.0))
        @test coerce_bind(wc, 21.5) == Celsius(21.5)
    end

    # `domain=` derives coerce (coerce-to-type then clamp/restrict) + reconcile (reset when out of domain).
    @testset "register_kind! domain=" begin
        register_kind!("ranged"; domain = w -> 0:Int(get(w.params, "max", 5)))
        rw = Widget("ranged", 0; max = 5)
        @test coerce_bind(rw, 99) == 5 && coerce_bind(rw, -3) == 0 && coerce_bind(rw, 3.4) == 3  # clamp+round
        @test reconcile_bind(rw, 4, Widget("ranged", 0; max = 5)) == 4        # still in domain → kept
        @test reconcile_bind(rw, 4, Widget("ranged", 0; max = 3)) == 0        # domain shrank → default

        register_kind!("oneof"; domain = w -> ["a", "b", "c"])                # a collection domain
        ow = Widget("oneof", "a")
        @test coerce_bind(ow, "b") == "b" && coerce_bind(ow, "z") == "a"      # member kept; non-member → default
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

    # Auto-registered front-end: `provide_frontend!`/`register_widget!`/`register_component!` populate the
    # process-global registry (from a package `__init__`), which the hub pulls via `extension_manifest()`
    # and injects into the page — no boot cell. `id` dedups a re-registration (a reload replaces, not stacks).
    @testset "front-end registry + extension_manifest" begin
        empty!(SlateExtensionsBase._FRONTEND)                     # isolate from any earlier registration

        provide_frontend!("SCRIPT_A"; id = "a")                   # classic script
        register_widget!("stars", "REG_STARS")                    # id "widget:stars", classic self-registering
        register_component!(Knob, "MODULE_JS")                    # TYPE form → kind "Main.Knob", ES module
        fs = frontend_scripts()
        @test fs["a"] == "SCRIPT_A"
        @test fs["widget:stars"] == "REG_STARS"
        @test fs["widget:Main.Knob"] == "MODULE_JS"

        provide_frontend!("SCRIPT_A_V2"; id = "a")                # same id → replace, not duplicate
        @test frontend_scripts()["a"] == "SCRIPT_A_V2"
        @test length(frontend_scripts()) == 3

        provide_frontend!("ANON")                                 # no id → content-hash key
        @test any(k -> startswith(k, "fe:"), keys(frontend_scripts()))

        # The manifest the hub pulls: a `frontend` list of (; id, js, esm, kind) mirroring the registry.
        m = extension_manifest()
        @test hasproperty(m, :frontend)
        byid = Dict(e.id => e for e in m.frontend)
        @test byid["widget:stars"].esm == false && byid["widget:stars"].kind == ""    # classic self-registering
        knob = byid["widget:Main.Knob"]
        @test knob.js == "MODULE_JS" && knob.esm == true && knob.kind == "Main.Knob"  # component ⇒ module + kind
        @test byid["a"].kind == ""
        @test length(m.frontend) == length(frontend_scripts())

        empty!(SlateExtensionsBase._FRONTEND)
    end

    # Lazy front-end: `required_assets(::Type{W})` + `ensure_widget_assets!` — Slate loads a widget's JS the
    # first time it's seen (no __init__), under the type-derived kind, idempotently.
    @testset "required_assets lazy loading" begin
        empty!(SlateExtensionsBase._FRONTEND)
        delete!(SlateExtensionsBase._ASSET_CHECKED, Gauge)       # isolate

        @test required_assets(Gauge) == "export default () => {}"
        @test required_assets(Knob) === nothing                  # no method → nothing (not an extension widget)
        @test !haskey(frontend_scripts(), "widget:Main.Gauge")   # not loaded until seen

        ensure_widget_assets!(Gauge)                             # first sight → register as a component
        @test frontend_scripts()["widget:Main.Gauge"] == "export default () => {}"
        g = only(e for e in extension_manifest().frontend if e.id == "widget:Main.Gauge")
        @test g.esm == true && g.kind == "Main.Gauge"

        ensure_widget_assets!(Gauge)                             # idempotent — no duplicate, no re-read
        @test length([e for e in extension_manifest().frontend if e.id == "widget:Main.Gauge"]) == 1
        ensure_widget_assets!(Knob)                              # a type with no assets → no-op
        @test !haskey(frontend_scripts(), "widget:Main.Knob")

        empty!(SlateExtensionsBase._FRONTEND)
    end

    # Package-global front-end: `__slate_frontend(slate_on)` + `ensure_module_frontend!` — a hook with no
    # bind to trigger it registers its editor-ext script AND its JS→Julia handlers, driven by Slate's
    # once-per-drain manifest pull (not an __init__/boot cell).
    @testset "ensure_module_frontend! (package-global hook)" begin
        empty!(SlateExtensionsBase._FRONTEND)
        empty!(SlateExtensionsBase._MODULE_FRONTEND_DONE)
        handlers = Dict{String,Any}()                            # stand-in for a notebook's __slate_handlers
        slate_on = (ch, f) -> (handlers[string(ch)] = f; nothing)

        @test ensure_module_frontend!(FakeExtPkg, slate_on)      # hook present → ran
        @test frontend_scripts()["FakeExtPkg.editor"] == "EDITOR_EXT"   # front-end registered
        @test haskey(handlers, "fake_channel")                   # handler installed via slate_on

        # Fires ONCE per (module, namespace generation): re-running with the SAME slate_on (as the
        # every-drain scan does) is a no-op — no re-read, no re-install.
        empty!(handlers)
        ensure_module_frontend!(FakeExtPkg, slate_on)
        @test isempty(handlers)                                  # skipped — not re-invoked
        @test length(extension_manifest().frontend) == 1

        # A NEW slate_on = a rebuilt namespace generation → re-fires, re-installing the handlers.
        handlers2 = Dict{String,Any}()
        slate_on2 = (ch, f) -> (handlers2[string(ch)] = f; nothing)
        ensure_module_frontend!(FakeExtPkg, slate_on2)
        @test haskey(handlers2, "fake_channel")                  # handlers back in the fresh table

        # A module with no hook contributes nothing.
        @test !ensure_module_frontend!(Base, slate_on)

        empty!(SlateExtensionsBase._FRONTEND)
        empty!(SlateExtensionsBase._MODULE_FRONTEND_DONE)
    end

    # Rich output: `slate_render` → a component descriptor (component+json) or an HTML fragment
    # (html+html), picked by `showable`; the descriptor is written by SEB's own minimal JSON writer.
    @testset "slate_render + display MIMEs" begin
        m = Meter(3, 5)
        @test showable(SlateComponentMIME(), m)
        @test !showable(SlateHtmlMIME(), m)
        d = slate_render(m)
        @test d["v"] == 1 && d["component"] == "Demo.Meter" && d["props"]["max"] == 5
        js = sprint(show, SlateComponentMIME(), m)
        @test occursin("\"component\":\"Demo.Meter\"", js) && occursin("\"v\":1", js)

        b = Banner("hi")
        @test showable(SlateHtmlMIME(), b) && !showable(SlateComponentMIME(), b)
        @test sprint(show, SlateHtmlMIME(), b) == "<b>hi</b>"

        @test slate_render(42) === nothing            # a plain value → not Slate-renderable
        @test !showable(SlateComponentMIME(), 42)

        # `component` accepts a Type (kind derived) and a props Dict/NamedTuple.
        @test component(Meter, (; a = 1))["component"] == "Main.Meter"

        # The minimal JSON writer: nesting, string escaping, non-finite floats → null.
        io = IOBuffer()
        SlateExtensionsBase._write_json(io, Dict("a" => Any[1, 2.5, true, nothing], "b" => "x\"y", "c" => Inf))
        s = String(take!(io))
        @test occursin("\"a\":[1,2.5,true,null]", s)
        @test occursin("\"b\":\"x\\\"y\"", s)
        @test occursin("\"c\":null", s)               # non-finite float → null (valid JSON)
    end

    # The `slate_on` context accessor — package code registers a JS→Julia handler through `:slate_ctx`.
    @testset "slate_on context accessor" begin
        @test slate_on("ch", identity) === nothing    # outside a cell → no-op
        handlers = Dict{String,Any}()
        task_local_storage(:slate_ctx, (; on = (c, f) -> (handlers[string(c)] = f; nothing))) do
            slate_on("compute", a -> a + 1)
        end
        @test haskey(handlers, "compute") && handlers["compute"](1) == 2
    end

    # Per-cell toolbar actions — the toolbar counterpart of the @bind Widget path.
    @testset "cell actions" begin
        empty!(SlateExtensionsBase._FRONTEND)               # isolate from earlier registrations
        # Direct construction + keyword defaults.
        a = CellAction("Pkg.Btn"; icon = "★", onclick = "doThing(cellId)")
        @test (a.id, a.icon, a.title, a.show, a.onclick) == ("Pkg.Btn", "★", "", "", "doThing(cellId)")
        @test to_cell_action(a) === a                       # identity passthrough

        # id must be a namespaced identifier — no quotes/spaces/brackets that break the DOM emit.
        @test_throws ArgumentError CellAction("has space"; icon = "x", onclick = "y")
        @test_throws ArgumentError CellAction("qu'ote"; icon = "x", onclick = "y")

        # auto_cell_action reflects fields; id is kind_for(T) (module-qualified, collision-proof).
        b = to_cell_action(InsertBtn())
        @test b.id == "Main.InsertBtn"
        @test b.icon == "➕" && b.show == "cell.kind === 'code'" && b.onclick == "window.myExtInsert(cellId)"

        # A missing REQUIRED field errors; a non-convertible value errors too.
        @test_throws ArgumentError auto_cell_action(NoClickBtn("x"))
        @test_throws ArgumentError to_cell_action(42)

        # register_cell_action! injects a plain (non-esm) frontend script that calls the host seam,
        # keyed so a re-register replaces rather than stacks.
        register_cell_action!(a)
        man = extension_manifest()
        entry = only(filter(e -> e.id == "cellaction:Pkg.Btn", man.frontend))
        @test entry.esm == false
        @test occursin("window.slateRegisterCellAction", entry.js)
        n_before = length(man.frontend)
        register_cell_action!(a)                            # idempotent — same id
        @test length(extension_manifest().frontend) == n_before

        # Reflection edges: a struct without `title`/`show` defaults them to ""; `exclude` drops a field.
        m = to_cell_action(MinBtn())
        @test (m.id, m.icon, m.title, m.show, m.onclick) == ("Main.MinBtn", "•", "", "", "f(cellId)")
        @test auto_cell_action(InsertBtn(); exclude = (:title,)).title == ""   # excluded → back to default ""

        # _js_string is the escaping that keeps injected data from breaking out of the <script> or the JS
        # string literal — the security-relevant core. Test it directly.
        jstr = SlateExtensionsBase._js_string
        @test jstr("hi") == "\"hi\""
        @test jstr("a\"b") == "\"a\\\"b\""                  # double quote escaped
        @test jstr("a\\b") == "\"a\\\\b\""                  # backslash escaped
        @test jstr("a\nb") == "\"a\\nb\""                   # newline → \n
        @test occursin("\\u003c", jstr("</script>")) && !occursin("<", jstr("</script>"))  # < never literal
        @test occursin("\\u0000", jstr("\0"))               # control char → \uXXXX

        # Defense-in-depth end to end: a `<` in `icon` / a `"` in `title` is escaped in the emitted JS,
        # so an action's DATA fields can't break the injected registration script.
        empty!(SlateExtensionsBase._FRONTEND)
        register_cell_action!(CellAction("Pkg.Esc"; icon = "<b>", title = "a\"b", onclick = "z()"))
        ejs = only(extension_manifest().frontend).js
        @test !occursin("<", ejs) && occursin("\\u003c", ejs)   # icon's `<` escaped, none left literal
        @test !occursin("a\"b", ejs)                            # title's quote escaped
    end

end
