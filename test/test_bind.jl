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
        @test findcell(r, "ctl").bind !== nothing
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
        @test findcell(r, "ctl").bind.value == 7         # not reset to default
    end

end
