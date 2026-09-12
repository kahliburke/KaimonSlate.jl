using Test
using BonitoSlate
using SlateExtensionsBase
import Bonito
import Observables

const BS = BonitoSlate

# The Slate execution context is a task-local NamedTuple under `:slate_ctx` — a zero-dependency
# convention, not an API call — so a test can supply one directly and exercise the real accessors
# with no server, no worker and no browser.
function with_ctx(f; widgets = Dict{Symbol,Any}(), values = Dict{Symbol,Any}())
    ctx = (; region = nothing, notebook = "test", side = "", regions = Symbol[],
             emit = (c, v) -> nothing, on = (c, f) -> nothing, off = (c) -> nothing,
             cleanup = (f) -> nothing, effect = (args...) -> nothing,
             bind_widget = n -> get(widgets, Symbol(n), nothing),
             bind_value  = n -> get(values, Symbol(n), nothing),
             on_bind = (n, f) -> (() -> nothing),
             bind_observable = n -> Observables.Observable{Any}(get(values, Symbol(n), nothing)),
             bind_names = () -> sort!(collect(keys(widgets))))
    task_local_storage(:slate_ctx, ctx) do
        f()
    end
end

w(kind, params, default) = SlateExtensionsBase.Widget(kind, Dict{String,Any}(params), default)

@testset "BonitoSlate" begin

@testset "reading the bind surface off the context" begin
    ws = Dict{Symbol,Any}(:a => w("slider", ("min" => 0.0, "max" => 1.0, "step" => 0.1), 0.0),
                          :b => w("checkbox", (), false))
    vs = Dict{Symbol,Any}(:a => 0.5, :b => true)
    with_ctx(widgets = ws, values = vs) do
        @test BS._slate_widget(:a).kind == "slider"
        @test BS._slate_value(:a) == 0.5
        @test BS._slate_widget(:missing) === nothing
        @test sort(BS._slate_bind_names()) == [:a, :b]
    end
    # Outside a cell there is no context at all; the accessors must say so rather than throw.
    @test BS._slate_widget(:a) === nothing
    @test BS._slate_bind_names() == Symbol[]
end

@testset "a core too old to populate the surface is named, not blamed on the user" begin
    # The compat bound gets the accessors but cannot force a core that FILLS them, so an older
    # Slate answers every one with `nothing` — which at the call site looks exactly like a control
    # that was never declared. The check has to fire before that confusion can happen.
    old = (; region = nothing, notebook = "test", side = "", regions = Symbol[],
             emit = (c, v) -> nothing, on = (c, f) -> nothing, off = (c) -> nothing,
             cleanup = (f) -> nothing, effect = (args...) -> nothing)
    @test !hasproperty(old, :bind_widget)
    err = try
        task_local_storage(:slate_ctx, old) do
            BS.bonito_controls(nothing, :anything)
        end
        nothing
    catch e
        sprint(showerror, e)
    end
    @test err !== nothing
    @test occursin("KaimonSlate", err)          # says what to upgrade
    @test occursin(BS._CORE_WITH_BINDS, err)    # and to which version
    @test !occursin("no such control", err)     # never the misleading one

    # A Dict-shaped context is the other permitted shape, and must be judged the same way.
    @test BS._require_bind_surface(Dict(:bind_widget => (n -> nothing))) === nothing
    @test_throws ErrorException BS._require_bind_surface(Dict(:region => nothing))
end

@testset "widget mapping follows the control's declared spec" begin
    with_ctx(values = Dict{Symbol,Any}(:s => 0.5)) do
        sl = BS._build_widget(:s, w("slider", ("min" => 0.0, "max" => 1.0, "step" => 0.25), 0.0))
        @test sl isa Bonito.Slider
        # The domain comes from the CONTROL, so the two cannot disagree about what is legal.
        @test sl.values[] == [0.0, 0.25, 0.5, 0.75, 1.0]
        @test sl.value[] == 0.5                      # opens at the current value, not the default
    end

    with_ctx(values = Dict{Symbol,Any}(:c => true)) do
        @test BS._build_widget(:c, w("checkbox", (), false)) isa Bonito.Checkbox
    end
    with_ctx(values = Dict{Symbol,Any}(:t => "hi")) do
        @test BS._build_widget(:t, w("text", (), "")) isa Bonito.TextField
    end
    with_ctx(values = Dict{Symbol,Any}(:n => 3.0)) do
        @test BS._build_widget(:n, w("number", (), 0.0)) isa Bonito.NumberInput
    end
    with_ctx(values = Dict{Symbol,Any}(:b => 0)) do
        @test BS._build_widget(:b, w("button", ("label" => "Go",), 0)) isa Bonito.Button
    end
end

@testset "select/radio take their options from the control" begin
    spec = w("select", ("opts" => Any[Dict("value" => "x", "label" => "X"),
                                      Dict("value" => "y", "label" => "Y")],), "x")
    with_ctx(values = Dict{Symbol,Any}(:s => "y")) do
        d = BS._build_widget(:s, spec)
        @test d isa Bonito.Dropdown
        @test d.option_index[] == 2               # opens on the CURRENT value, not the first option
    end
    @test BS._option_values(spec.params) == ["x", "y"]
    # bare values and {value,label} pairs both normalise
    @test BS._option_values(Dict{String,Any}("options" => Any[1, 2, 3])) == [1, 2, 3]
    @test BS._option_values(Dict{String,Any}()) == Any[]
end

@testset "an unsupported kind is refused by name" begin
    # A control that looks right and edits the wrong thing is worse than one that says it cannot be
    # drawn — the message has to name the control and the kind so the fix is obvious.
    with_ctx() do
        err = try; BS._build_widget(:pick, w("tableselect", (), 0)); catch e; sprint(showerror, e); end
        @test occursin("pick", err)
        @test occursin("tableselect", err)
    end
end

@testset "a value off the widget's grid opens on the nearest tick" begin
    vals = [0.0, 0.25, 0.5, 0.75, 1.0]
    @test BS._clamp_to(vals, 0.5) == 0.5
    @test BS._clamp_to(vals, 0.3) == 0.25          # a float range rarely holds a stored value exactly
    @test BS._clamp_to(vals, 99.0) == 1.0          # clamped, not an error
    @test BS._clamp_to(vals, nothing) == 0.0       # no value yet → the first tick
    @test BS._clamp_to(["a", "b"], "zzz") == "a"   # non-numeric: no nearest, so fall back
end

@testset "the value Observable is found across widget types" begin
    with_ctx(values = Dict{Symbol,Any}(:s => 0.5, :c => false)) do
        sl = BS._build_widget(:s, w("slider", ("min" => 0.0, "max" => 1.0, "step" => 0.5), 0.0))
        cb = BS._build_widget(:c, w("checkbox", (), false))
        @test BS._widget_value_observable(sl) isa Observables.AbstractObservable
        @test BS._widget_value_observable(cb) isa Observables.AbstractObservable
    end
    @test BS._widget_value_observable(42) === nothing   # not a widget → nothing, not an error
end

@testset "bonito_controls refuses what it cannot do" begin
    # No execution context: the caller is outside a cell.
    err = try; BS.bonito_controls(nothing, :a); catch e; sprint(showerror, e); end
    @test occursin("Slate cell", err)

    with_ctx(widgets = Dict{Symbol,Any}(:a => w("slider", ("min" => 0, "max" => 1), 0))) do
        # Naming nothing is a mistake, not an empty strip.
        e1 = try; BS.bonito_controls(nothing); catch e; sprint(showerror, e); end
        @test occursin("name at least one", e1)
        # An undeclared control names itself and says how to declare it.
        e2 = try; BS.bonito_controls(nothing, :nope); catch e; sprint(showerror, e); end
        @test occursin("nope", e2) && occursin("@bind", e2)
    end

    # `:all` over a notebook with no controls is a mistake too, not an empty node.
    with_ctx() do
        e3 = try; BS.bonito_controls(nothing, :all); catch e; sprint(showerror, e); end
        @test occursin("no @bind controls", e3)
    end
end

end # BonitoSlate
