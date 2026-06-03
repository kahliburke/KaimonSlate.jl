# Reactive @bind widget tests.
#   julia --startup-file=no --project=/tmp/report-devenv test/report/test_bind.jl
using Test

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine
findcell(r, id) = r.cells[findfirst(c -> c.id == id, r.cells)]

@testset "ReportEngine bind" begin

    @testset "parse_bind" begin
        s = parse_bind("@bind x Slider(0:10)")
        @test s !== nothing && s.name == :x && s.widget == "slider"
        @test s.params["min"] == 0 && s.params["max"] == 10 && s.value == 0
        @test parse_bind("y = 1") === nothing
        @test parse_bind("@bind flag Checkbox(true)").value === true
        sel = parse_bind("@bind c Select([\"a\", \"b\"])")
        @test sel.widget == "select" && sel.value == "a" && sel.params["options"] == ["a", "b"]
    end

    @testset "bind cell writes its variable; dependents react" begin
        r = parse_report("#%% code id=ctl\n@bind n Slider(1:10)\n#%% code id=use\nm = n * 2")
        build_dependencies!(r)
        @test !isempty(findcell(r, "ctl").binds)
        @test :n in findcell(r, "ctl").writes
        @test "ctl" in findcell(r, "use").deps          # dependent reads the bound var
        eval_stale!(r)
        @test getproperty(r.mod, :n) == 1               # default
        @test getproperty(r.mod, :m) == 2

        set_bind_value!(r, findcell(r, "ctl"), 5)        # "move the slider"
        findcell(r, "use").state = STALE                 # (server marks dependents)
        eval_stale!(r)
        @test getproperty(r.mod, :n) == 5
        @test getproperty(r.mod, :m) == 10               # dependent recomputed
    end

    @testset "coerce_bind keeps integer sliders integer" begin
        @test coerce_bind(parse_bind("@bind k Slider(0:100)"), 7.0) === 7
        @test coerce_bind(parse_bind("@bind f Slider(0:0.1:1)"), 0.5) === 0.5
        @test coerce_bind(parse_bind("@bind b Checkbox(false)"), true) === true
    end

    @testset "widget value survives unrelated edits (re-inference)" begin
        r = parse_report("#%% code id=ctl\n@bind n Slider(1:10)\n#%% code id=x\nz = 1")
        build_dependencies!(r)
        set_bind_value!(r, findcell(r, "ctl"), 7)
        build_dependencies!(r)                           # re-infer (e.g. after an edit)
        @test findcell(r, "ctl").binds[1].value == 7     # not reset to default
    end

    @testset "expanded widget types: parse + defaults + coerce" begin
        w(src) = parse_bind(src)
        @test w("@bind t Toggle(true)").widget == "toggle"
        @test w("@bind t Toggle(true)").value === true
        @test w("@bind s TextArea(\"hi\")").widget == "textarea"
        @test w("@bind c ColorPicker(\"#ff8800\")").widget == "color"
        @test w("@bind c ColorPicker(\"#ff8800\")").value == "#ff8800"
        @test w("@bind d DateField(\"2026-01-02\")").widget == "date"
        @test w("@bind tm TimeField(\"08:30\")").widget == "time"
        @test w("@bind r Radio([\"a\",\"b\",\"c\"])").widget == "radio"
        @test w("@bind r Radio([\"a\",\"b\"], \"b\")").value == "b"
        ms = w("@bind m MultiSelect([\"x\",\"y\",\"z\"], [\"x\",\"z\"])")
        @test ms.widget == "multiselect" && ms.value == ["x", "z"]
        @test w("@bind m MultiSelect([\"x\",\"y\"])").value == Any[]
        @test w("@bind b Button(\"Go\")").widget == "button"
        @test w("@bind b Button(\"Go\")").value == 0
        @test w("@bind b Button(\"Go\")").params["label"] == "Go"
        nf = w("@bind n NumberField(0, 10, 3)")
        @test nf.widget == "number" && nf.value == 3 && nf.params["min"] == 0 && nf.params["max"] == 10

        # coercion from browser JSON
        @test coerce_bind(w("@bind t Toggle(false)"), 1) === true
        @test coerce_bind(w("@bind b Button(\"x\")"), 4.0) === 4
        @test coerce_bind(w("@bind m MultiSelect([\"x\",\"y\"])"), ["x", "y"]) == ["x", "y"]
        @test coerce_bind(w("@bind c ColorPicker()"), "#123456") == "#123456"
    end

    @testset "parse_binds: control-group cells (multiple @bind per cell)" begin
        # all-@bind body → one spec per line, in order
        specs = parse_binds("@bind a Slider(1:10)\n@bind b Checkbox(true)\n@bind c Select([\"x\",\"y\"])")
        @test [s.name for s in specs] == [:a, :b, :c]
        @test [s.widget for s in specs] == ["slider", "checkbox", "select"]

        @test isempty(parse_binds(""))                   # empty
        @test isempty(parse_binds("x = 1"))              # ordinary code
        @test isempty(parse_binds("@bind a Slider(1:10)\nx = 1"))  # mixed → not a group
        @test length(parse_binds("@bind a Slider(1:10)")) == 1     # single still parses
    end

    @testset "group cell: each bind writes its var; per-name value set" begin
        r = parse_report("#%% code id=ctl\n@bind a Slider(1:10)\n@bind b Slider(0:0.5:5)\n" *
                         "#%% code id=use\nm = a + b")
        build_dependencies!(r)
        ctl = findcell(r, "ctl")
        @test length(ctl.binds) == 2
        @test :a in ctl.writes && :b in ctl.writes
        @test "ctl" in findcell(r, "use").deps
        eval_stale!(r)
        @test getproperty(r.mod, :a) == 1 && getproperty(r.mod, :b) == 0
        @test getproperty(r.mod, :m) == 1

        set_bind_value!(r, ctl, :b, 2.5)                 # set one of the two
        findcell(r, "use").state = STALE
        eval_stale!(r)
        @test getproperty(r.mod, :b) == 2.5
        @test getproperty(r.mod, :m) == 3.5              # a (1) + b (2.5)
        @test ctl.binds[1].value == 1                    # the other bind unchanged
    end

    @testset "injected @bind macro: unrecognized bind code evaluates, no error" begin
        # a cell mixing @bind with code isn't a group cell, so it runs as ordinary
        # Julia — the injected macro assigns the widget default instead of erroring.
        r = parse_report("#%% code id=mix\n@bind w Slider(2:10)\nq = w + 1")
        build_dependencies!(r)
        eval_stale!(r)
        @test isempty(findcell(r, "mix").binds)          # not intercepted as a bind cell
        @test getproperty(r.mod, :w) == 2                # macro assigned the default (first of 2:10)
        @test getproperty(r.mod, :q) == 3
        @test findcell(r, "mix").state == FRESH          # no error
    end

end
