# Reactive @bind widget tests.
#   julia --startup-file=no --project=/tmp/report-devenv test/report/test_bind.jl
#
# `@bind` is real Julia: widgets are constructors, `@bind name W(…)` runs as code
# (so dynamic args work), and the control is reported back through eval — not parsed.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine
const RE = ReportEngine
findcell(r, id) = r.cells[findfirst(c -> c.id == id, r.cells)]

@testset "ReportEngine bind" begin

    @testset "widget constructors build specs" begin
        s = RE.Slider(0:10)
        @test s.kind == "slider" && s.params["min"] == 0 && s.params["max"] == 10 && s.default == 0
        @test RE.Checkbox(true).default === true
        sel = RE.Select(["a", "b"])
        # Options normalize to `[{value,label}]` specs (the labeled-options form), not bare values.
        @test sel.kind == "select" && sel.default == "a" &&
              [o["value"] for o in sel.params["options"]] == ["a", "b"]
        @test RE.Toggle(true).kind == "toggle"
        @test RE.TextArea("hi").kind == "textarea"
        @test RE.ColorPicker("#ff8800").default == "#ff8800"
        @test RE.Radio(["a", "b"], "b").default == "b"
        ms = RE.MultiSelect(["x", "y", "z"], ["x", "z"])
        @test ms.kind == "multiselect" && ms.default == ["x", "z"]
        @test RE.MultiSelect(["x", "y"]).default == Any[]
        @test RE.Button("Go").params["label"] == "Go" && RE.Button("Go").default == 0
        nf = RE.NumberField(0, 10, 3)
        @test nf.kind == "number" && nf.default == 3 && nf.params["min"] == 0 && nf.params["max"] == 10
        # kwargs (the natural Pluto-ish syntax) are real now, not a parser special case
        sk = RE.Slider(0.0:0.01:1.0; default = 0.5, label = "frac")
        @test sk.default == 0.5 && sk.params["label"] == "frac"
    end

    @testset "coerce_bind: browser JSON → widget type" begin
        @test RE.coerce_bind(RE.Slider(0:100), 7.0) === 7        # integer slider stays Int
        @test RE.coerce_bind(RE.Slider(0:0.1:1), 0.5) === 0.5    # float slider stays Float
        @test RE.coerce_bind(RE.Checkbox(false), true) === true
        @test RE.coerce_bind(RE.Toggle(false), 1) === true
        @test RE.coerce_bind(RE.Button("x"), 4.0) === 4
        @test RE.coerce_bind(RE.MultiSelect(["x", "y"]), ["x", "y"]) == ["x", "y"]
        @test RE.coerce_bind(RE.ColorPicker(), "#123456") == "#123456"
    end

    @testset "custom_widget: third-party kind passes through the value contract" begin
        w = RE.custom_widget("mathfield"; label = "answer")
        @test w.kind == "mathfield" && w.default == "" && w.params["label"] == "answer"
        @test RE.custom_widget("mathfield", "\\frac{1}{2}").default == "\\frac{1}{2}"   # positional default carries
        # coerce is TYPE-DRIVEN from the default even for an unregistered kind: a String-valued field
        # coerces a stray browser value to String (see SlateExtensionsBase `coerce_value`).
        @test RE.coerce_bind(w, "x^2 + 1") == "x^2 + 1"
        @test RE.coerce_bind(w, 42) === "42"                                            # coerced to the default's String type
        # reconcile keeps the user's value across a re-run (same custom kind), resets on a kind change
        @test RE.reconcile_bind(w, "kept", RE.custom_widget("mathfield")) == "kept"
        @test RE.reconcile_bind(w, "kept", RE.Slider(0:10)) == 0                        # kind changed → default
    end

    @testset "TableSelect binds the clicked row as a NamedTuple" begin
        ts = RE.TableSelect([(sym = "AAPL", px = 42.0), (sym = "MSFT", px = 13.5)])
        @test ts.kind == "tableselect"
        @test [c["name"] for c in ts.params["columns"]] == ["sym", "px"]   # object-form columns
        @test ts.default == 0                                   # nothing selected initially
        # No selection → nothing; a valid 1-based index → the row as a NamedTuple (field per column)
        @test RE.wrap_value(ts, 0) === nothing
        row = RE.wrap_value(ts, 1)
        @test row === (sym = "AAPL", px = 42.0)
        @test row.px == 42.0 && row.sym == "AAPL"               # struct-like field access
        # coerce clamps the browser's row index to the known rows (out of range → 0 = none)
        @test RE.coerce_bind(ts, 2.0) === 2
        @test RE.coerce_bind(ts, 99) === 0 && RE.coerce_bind(ts, 0) === 0
        # reconcile keeps the selected index across a re-run while it stays in range
        @test RE.reconcile_bind(ts, 2, ts) == 2
        ts1 = RE.TableSelect([(sym = "AAPL", px = 42.0)])       # a re-run that now has only 1 row
        @test RE.reconcile_bind(ts, 2, ts1) == 0               # index 2 no longer valid → default
    end

    @testset "reconcile: keep value unless type-changed or out of domain" begin
        @test RE.reconcile_bind(RE.Slider(0:10), 5, RE.Slider(0:10)) == 5        # in range → keep
        @test RE.reconcile_bind(RE.Slider(0:10), 8, RE.Slider(0:5)) == 0         # out of range → default
        @test RE.reconcile_bind(RE.Slider(0:10), 5, RE.Toggle(false)) === false  # type change → default
        @test RE.reconcile_bind(RE.Select(["a", "b"]), "b", RE.Select(["a", "b", "c"])) == "b"
        @test RE.reconcile_bind(RE.Select(["a", "b"]), "b", RE.Select(["a", "c"])) == "a"  # gone → default
        # multiselect drops now-invalid options
        @test RE.reconcile_bind(RE.MultiSelect(["x", "y", "z"]), ["x", "z"],
                                 RE.MultiSelect(["x", "y"])) == ["x"]
        # `_do_bind` handles the "?" placeholder (browser set a value before this bind cell's first
        # run this session): it isn't a real type change, so the pending value survives, coerced
        # against the real widget, instead of being discarded to the default.
        lk = ReentrantLock()
        regp = Dict{Symbol,Tuple{RE.Widget,Any}}(:k => (RE.Widget("?", Dict{String,Any}(), 7), 7))
        @test RE._do_bind(regp, lk, :k, RE.Slider(0:10)) == 7
        regp2 = Dict{Symbol,Tuple{RE.Widget,Any}}(:k => (RE.Widget("?", Dict{String,Any}(), 7.0), 7.0))
        @test RE._do_bind(regp2, lk, :k, RE.Slider(0:10)) == 7   # coerced like a normal Int slider set
    end

    @testset "bind cell: control reported by eval; dependents react" begin
        r = parse_report("#%% code id=ctl\n@bind n Slider(1:10)\n#%% code id=use\nm = n * 2")
        build_dependencies!(r)
        @test :n in findcell(r, "ctl").writes              # graph sees the write (static)
        @test "ctl" in findcell(r, "use").deps             # dependent reads the bound var
        @test isempty(findcell(r, "ctl").binds)            # not populated until eval
        eval_stale!(r)
        @test !isempty(findcell(r, "ctl").binds)           # control reported by eval
        @test findcell(r, "ctl").binds[1].widget == "slider"
        @test Base.invokelatest(getproperty, r.mod, :n) == 1 && Base.invokelatest(getproperty, r.mod, :m) == 2

        set_bind_value!(r, findcell(r, "ctl"), 5)          # "move the slider"
        findcell(r, "use").state = STALE                   # (server marks dependents)
        eval_stale!(r)
        @test Base.invokelatest(getproperty, r.mod, :n) == 5 && Base.invokelatest(getproperty, r.mod, :m) == 10
        @test findcell(r, "ctl").binds[1].value == 5       # host-side spec mirrors it
    end

    @testset "mixed cell: @bind and code in one cell both work" begin
        r = parse_report("#%% code id=mix\n@bind w Slider(2:10)\nq = w + 1")
        build_dependencies!(r)
        @test :w in findcell(r, "mix").writes && :q in findcell(r, "mix").writes
        eval_stale!(r)
        @test findcell(r, "mix").state == FRESH
        @test Base.invokelatest(getproperty, r.mod, :w) == 2 && Base.invokelatest(getproperty, r.mod, :q) == 3
        @test !isempty(findcell(r, "mix").binds)           # control reported even though mixed
    end

    @testset "Choice is transparent in convert/index/construct contexts" begin
        # A labeled Select binds a `Choice`; it must behave like its value wherever a `convert` flows.
        c = RE.Choice(8, "8 heads", 4)
        @test convert(Int, c) === 8                        # typed field / local / collection element
        @test Int(c) === 8                                 # explicit numeric construction
        @test (let x::Int = c; x end) === 8                # typed local assignment
        @test Int[c, c] == [8, 8]                          # typed collection element
        @test [10, 20, 30, 40, 50, 60, 70, 80][c] == 80    # indexing (to_index)
        @test c == 8 && c.value === 8 && c.label == "8 heads"
        # The scalar-only `convert` restriction keeps Choice→Choice conversion intact (Selection needs it).
        @test eltype(RE.Choice[c, c]) === RE.Choice
    end

    @testset "a mixed @bind cell is memoizable, keyed on the control value" begin
        r = parse_report("#%% code id=up\nd = 3\n#%% code id=mix\n@bind k Slider(1:5)\ny = d * k")
        build_dependencies!(r); eval_stale!(r)
        mix = findcell(r, "mix")
        @test !isempty(mix.binds)
        @test RE._memoizable(mix)                          # bind cells now cacheable (scaffold-replay on restore)
        # the control's current value is folded into the key, so changing it invalidates the entry
        k1 = RE._memo_key(r, mix)
        set_bind_value!(r, mix, :k, 5)
        k2 = RE._memo_key(r, mix)
        @test !isempty(k1) && k1 != k2
    end

    @testset "dynamic range: widget args are reads; range re-evaluates" begin
        r = parse_report("#%% code id=hi\nhi = 5\n#%% code id=ctl\n@bind k Slider(1:hi)")
        build_dependencies!(r)
        @test :hi in findcell(r, "ctl").reads              # widget arg is a read
        @test "hi" in findcell(r, "ctl").deps              # bind cell depends on hi's writer
        eval_stale!(r)
        @test findcell(r, "ctl").binds[1].params["max"] == 5
        set_bind_value!(r, findcell(r, "ctl"), 4)
        @test Base.invokelatest(getproperty, r.mod, :k) == 4
        # hi grows → bind cell re-runs, range expands; in-range value is preserved
        Core.eval(r.mod, :(hi = 8))
        findcell(r, "ctl").state = STALE
        eval_stale!(r)
        @test findcell(r, "ctl").binds[1].params["max"] == 8   # range updated live
        @test Base.invokelatest(getproperty, r.mod, :k) == 4                       # value preserved (still in range)
    end

    @testset "value persists across a bind-cell re-run (registry reconcile)" begin
        r = parse_report("#%% code id=ctl\n@bind n Slider(1:10)")
        build_dependencies!(r); eval_stale!(r)
        set_bind_value!(r, findcell(r, "ctl"), 7)
        @test Base.invokelatest(getproperty, r.mod, :n) == 7
        findcell(r, "ctl").state = STALE                   # re-run the bind cell
        eval_stale!(r)
        @test Base.invokelatest(getproperty, r.mod, :n) == 7                  # not reset to default
        @test findcell(r, "ctl").binds[1].value == 7
    end

    @testset "group cell: multiple @bind; per-name value set" begin
        r = parse_report("#%% code id=ctl\n@bind a Slider(1:10)\n@bind b Slider(0:0.5:5)\n" *
                         "#%% code id=use\nm = a + b")
        build_dependencies!(r)
        ctl = findcell(r, "ctl")
        @test :a in ctl.writes && :b in ctl.writes
        @test "ctl" in findcell(r, "use").deps
        eval_stale!(r)
        @test length(ctl.binds) == 2
        @test Base.invokelatest(getproperty, r.mod, :a) == 1 && Base.invokelatest(getproperty, r.mod, :b) == 0 && Base.invokelatest(getproperty, r.mod, :m) == 1

        set_bind_value!(r, ctl, :b, 2.5)                   # set one of the two
        findcell(r, "use").state = STALE
        eval_stale!(r)
        @test Base.invokelatest(getproperty, r.mod, :b) == 2.5 && Base.invokelatest(getproperty, r.mod, :m) == 3.5
        @test ctl.binds[findfirst(s -> s.name == :a, ctl.binds)].value == 1   # other unchanged
    end

    @testset "@onclick: a superseded handler is cancelled at its next Reactive write (no pause needed)" begin
        tokens = Dict{Symbol,Any}()
        log = Int[]
        r = RE.Reactive(:level, 0, _ -> nothing)
        done1, done2 = Ref(false), Ref(false)
        handler1 = _ -> begin       # NO `pause()` calls — relies on the write itself being a checkpoint
            for i in 1:5
                r[] = i             # should throw _Cancelled here, before ever appending to log
                push!(log, i)
            end
            done1[] = true
        end
        handler2 = _ -> begin
            r[] = 99
            push!(log, 99)
            done2[] = true
        end
        RE.__on_fire!(tokens, :fill, handler1, nothing)
        RE.__on_fire!(tokens, :fill, handler2, nothing)   # supersedes handler1 before it has run any code
        for _ in 1:200   # both tasks are spawned async — wait for handler2 to finish
            done2[] && break
            sleep(0.01)
        end
        @test done2[]
        @test !done1[]            # handler1 never completed — cancelled at (or before) its first write
        @test 1 ∉ log             # handler1's loop body never executed, not even its first iteration
        @test r[] == 99           # handler2's write landed cleanly; handler1 never raced it
    end

    @testset "valueless set on a button is a click: server increments the count" begin
        # The core new behaviour, at the registry layer: a button's value IS its click count, so a
        # set with `nothing` increments it server-side — the caller never needs (or races) the count.
        reg = Dict{Symbol,Tuple{RE.Widget,Any}}(:go => (RE.Button("Run"), 0))
        lk = ReentrantLock()
        @test RE._do_set_bind(reg, lk, :go, nothing) == 1       # click: 0 → 1
        @test RE._do_set_bind(reg, lk, :go, nothing) == 2       # click: 1 → 2
        @test reg[:go][2] == 2
        @test RE._do_set_bind(reg, lk, :go, 10) == 10           # an explicit value (browser path) still sets exactly
        # the increment is button-only: a valueless slider set just coerces (no magic count bump)
        reg2 = Dict{Symbol,Tuple{RE.Widget,Any}}(:s => (RE.Slider(0:10), 3))
        @test RE._do_set_bind(reg2, lk, :s, 6) == 6
    end

    @testset "@bind Button: a valueless click increments the global AND fires @onclick" begin
        r = parse_report("#%% code id=ctl\n@bind go Button(\"Run\")\n@onclick go (fires[] += 1)\n" *
                         "#%% code id=use\nseen = go")
        build_dependencies!(r); eval_stale!(r)
        # inject the counter the handler bumps AFTER eval (the module exists now); the @onclick
        # closure only resolves `fires` when it fires, so registering it earlier is fine.
        Core.eval(r.mod, :(const fires = $(Ref(0))))
        @test findcell(r, "ctl").binds[1].widget == "button"
        @test Base.invokelatest(getproperty, r.mod, :go) == 0

        set_bind_value!(r, findcell(r, "ctl"), :go, nothing)    # click — no value passed
        findcell(r, "use").state = STALE; eval_stale!(r)
        @test Base.invokelatest(getproperty, r.mod, :go) == 1   # count advanced server-side
        @test Base.invokelatest(getproperty, r.mod, :seen) == 1 # a reader reacted

        set_bind_value!(r, findcell(r, "ctl"), :go, nothing)    # click again
        @test Base.invokelatest(getproperty, r.mod, :go) == 2
        @test findcell(r, "ctl").binds[1].value == 2            # host-side spec mirrors it

        # @onclick dispatch is async (__on_fire! spawns a task) — wait for both fires to land
        fires = Base.invokelatest(getproperty, r.mod, :fires)
        for _ in 1:200; fires[] == 2 && break; sleep(0.01); end
        @test fires[] == 2                                       # the handler fired on each click
    end

end
