# A NamedTuple cell value renders as a grid of fields rather than its one-line text.
using ReTest
using KaimonSlate
const RE = KaimonSlate.ReportEngine

# Stand-ins for a units package and an uncertainty package: what matters is only their `show`.
struct _Qty; v::Float64; u::String; end
Base.show(io::IO, ::MIME"text/plain", q::_Qty) = print(io, q.v, " ", q.u)
struct _Unc; v::Float64; e::Float64; u::String; end
Base.show(io::IO, ::MIME"text/plain", q::_Unc) = print(io, "(", q.v, " ± ", q.e, ") ", q.u)

@testset "a NamedTuple renders as a record" begin
    h = RE.record_html((; f0 = _Qty(1006.5842420897408, "Hz"), ζ = 0.07905694150420947, n = 3, ok = true, note = "a <b>"))
    @test occursin("class=\"slate-record\"", h)
    # The number to five significant figures, the unit beside it.
    @test occursin("<span class=\"srec-k\">f0</span><span class=\"srec-v\">1006.6<span class=\"srec-u\">Hz</span>", h)
    @test occursin(">0.079057<", h) && occursin(">3<", h)
    @test occursin("srec-bool yes", h) && occursin("a &lt;b&gt;", h)
    # An uncertainty set apart from its value, the unit still split off.
    u = RE.record_html((; f0 = _Unc(1007.0213, 71.04, "Hz")))
    @test occursin(">1007.0<span class=\"srec-err\"> ± 71.04</span><span class=\"srec-u\">Hz</span>", u)
    # Nested NamedTuples are sub-grids; text that is not a number keeps its text.
    n = RE.record_html((; plasma = (; P = 1500.0, f = 0.6), label = :x, v = [1.0, 2.0]))
    @test occursin("srec-f srec-nest", n) && count("srec-grid", n) == 2
    @test occursin("srec-text", n)
    @test RE.record_html(NamedTuple()) === nothing
    # SI base units read in the common unit, with the prefix that puts the number between 1 and 1000.
    @test RE.common_units("4.3247e8", "", "m² kg s⁻³") == ("432.47", "", "MW")
    @test RE.common_units("1.3333e6", "", "kg s⁻³") == ("1.3333", "", "MW/m²")
    @test RE.common_units("62015.0", "", "m² kg s⁻³") == ("62.015", "", "kW")
    @test RE.common_units("0.01", "0.001", "m² kg s⁻² A⁻²") == ("10.0", "1.0", "mH")
    @test RE.common_units("900.0", "", "m²") == ("900.0", "", "m²")               # no prefix on an area
    @test RE.common_units("12.0", "", "Hz") == ("12.0", "", "Hz")                 # not base units: as it was
    @test RE.common_units("3.0", "", "m kg") == ("3.0", "", "m kg")               # no common name: as it was
    @test RE.common_units_text("(1.59e9 ± 2.0e7) m² kg s⁻³") == "1.59 ± 0.02 GW"
    @test occursin(">432.47<span class=\"srec-u\">MW</span>", RE.record_html((; P = _Qty(4.3247e8, "m² kg s⁻³"))))
    # Through the capture: the grid for the page, and the text kept for an agent.
    r = RE.parse_report("#%% code id=c\n(; a = 1.23456789, b = 2)"); RE.build_dependencies!(r); RE.eval_report!(r)
    o = r.cells[1].output
    @test any(ch -> ch.mime == "application/vnd.kaimonslate.html+html" && occursin("slate-record", String(ch.data)), o.display)
    @test occursin("a = 1.23456789", o.value_repr)
end
