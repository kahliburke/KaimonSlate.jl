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

    @testset "reconcile: keep value unless type-changed or out of domain" begin
        @test RE._reconcile_bind(RE.Slider(0:10), 5, RE.Slider(0:10)) == 5        # in range → keep
        @test RE._reconcile_bind(RE.Slider(0:10), 8, RE.Slider(0:5)) == 0         # out of range → default
        @test RE._reconcile_bind(RE.Slider(0:10), 5, RE.Toggle(false)) === false  # type change → default
        @test RE._reconcile_bind(RE.Select(["a", "b"]), "b", RE.Select(["a", "b", "c"])) == "b"
        @test RE._reconcile_bind(RE.Select(["a", "b"]), "b", RE.Select(["a", "c"])) == "a"  # gone → default
        # multiselect drops now-invalid options
        @test RE._reconcile_bind(RE.MultiSelect(["x", "y", "z"]), ["x", "z"],
                                 RE.MultiSelect(["x", "y"])) == ["x"]
        # `_do_set_bind`'s "?" placeholder (browser set a value before this bind cell's first run
        # this session) isn't a real type change — the pending value survives, coerced against the
        # real widget, instead of being discarded to the default.
        placeholder = RE.Widget("?", Dict{String,Any}(), 7)
        @test RE._reconcile_bind(placeholder, 7, RE.Slider(0:10)) == 7
        @test RE._reconcile_bind(placeholder, 7.0, RE.Slider(0:10)) == 7   # coerced like a normal Int slider set
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

end
