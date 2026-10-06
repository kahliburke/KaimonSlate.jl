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

# Clicking a field points at the source that produced it. The rule is per FIELD: a variable is what
# was "used to assign", a literal is not, and a record nested in the tuple is its own expression.
@testset "a record field resolves to its source" begin
    span(src, f) = (r = RE.record_field_span(src, f); r === nothing ? nothing : String(codeunits(src)[r[1]:r[2]]))

    @testset "the variable that was put in" begin
        @test span("(; f0 = measured, n = 3)", "f0") == "measured"
        @test span("res = (; a = 1, b = bee)", "b") == "bee"
        @test span("(; f0, ζ)", "ζ") == "ζ"                       # shorthand: the name IS the variable
        @test span("(; a = f(g(h(1))), b = 2)", "a") == "f(g(h(1)))"
        @test span("(; outer = 1, inner = (; x = 2))", "inner") == "(; x = 2)"
    end

    @testset "a literal has no variable, so the tuple is what is pointed at" begin
        whole = "(; f0 = 1006.6, n = 3)"
        @test span(whole, "f0") == whole
        # A number is one token and a string is three, so a token count would treat them
        # differently; both are literals and both must land on the tuple.
        @test span("(; a = x, b = \"lit\")", "b") == "(; a = x, b = \"lit\")"
        @test span("(; a = true, b = 2)", "a") == "(; a = true, b = 2)"
    end

    @testset "nothing is pointed at rather than the wrong thing" begin
        @test span("(; a = 1, b = 2)", "nope") === nothing
        @test span("", "a") === nothing
        @test span("(; a = 1", "a") === nothing                   # unclosed: no tuple to name
        @test span("foo(a = 1)", "a") === nothing                 # a call's keyword argument, not a field
        # …but a real tuple after a call still resolves: the `)` above it is not this bracket's callee.
        @test span("res = foo(a = 1)\n(; a = res.x)", "a") == "res.x"
    end

    # The editor indexes UTF-16 units and the tokens are byte ranges, so a multibyte or astral
    # character ABOVE the tuple would slide the mark left of the text it names.
    @testset "offsets survive characters outside ASCII" begin
        src = "ζ = 1\n(; a = beta, b = 2)"
        r = RE.record_field_range(src, "a")
        @test r !== nothing
        units = Char[]; for c in src; push!(units, c); ncodeunits(c) > 3 && push!(units, c); end
        @test String(units[(r[1] + 1):r[2]]) == "beta"
    end
end

# The reader can ask for Julia's own text instead of the grid. Both forms ship inside the record
# chunk, because the text repr beside the cell is dropped wherever richer output exists
# (`_cell_view`) — a preference built on that one would work live and blank a static export.
@testset "a collection field shows its contents, not its type" begin
    # `show(::MIME"text/plain", ::Vector)` is a HEADER line followed by the elements, and the field
    # summary takes the first line — which reduced a collection to `8-element Vector{Tuple{Int64,
    # Int64}}:`, the type and none of the data. Dicts and sets print the same way.
    val(h, i = 1) = collect(eachmatch(r"<span class=\"srec-v[^\"]*\">([^<]*)", h))[i].captures[1]

    h = RE.record_html((; by_nfp = [(i, 3i) for i in 1:8]))
    @test occursin("(1, 3)", val(h))                  # the data is there …
    @test !occursin("element Vector", val(h))         # … and the type signature is not
    @test occursin("8 total", val(h))                 # with the count kept, not cut by the cap

    # Short enough to show whole → shown whole, keeping the container's own delimiters rather than a
    # Vector's brackets. A single row is a collection, not a stack, so it comes down this path too.
    @test occursin("helicity = 0", val(RE.record_html((; by_helicity = [(helicity = 0, count = 4)]))))
    @test startswith(val(RE.record_html((; d = Dict(:a => 1)))), "Dict")
    @test startswith(val(RE.record_html((; s = Set([7]))))  , "Set")

    @testset "and bounded by the head, not by truncating the whole" begin
        # The cap at the end of the summary cannot undo the cost of building the string, so a long
        # vector must never be rendered in full first. Timed rather than asserted structurally: a
        # million elements through `show` takes seconds, six take microseconds.
        big = collect(1:1_000_000)
        RE.record_html((; warm = [1, 2, 3]))                      # compile first
        t = @elapsed hb = RE.record_html((; big = big))
        @test t < 1.0
        @test occursin("1000000 total", val(hb))
        @test length(val(hb)) <= 141
    end
end

# Rows of the same shape render as a stack of cards the page can fan out, rather than as the line of
# text that spells the data's shape out. The decision is made from the ELEMENT TYPE, so it must be
# `fieldnames` and not `isconcretetype`: a column whose values are an Int in one row and a Float in
# the next still has fixed keys, and that is the whole question.
@testset "rows of the same shape become a card stack" begin
    rows(n) = [(nfp = i, count = 3i) for i in 1:n]
    cards(h) = count("class=\"srec-card\"", h)
    val(h, i = 1) = collect(eachmatch(r"<span class=\"srec-v[^\"]*\">([^<]*)", h))[i].captures[1]

    @testset "which vectors qualify" begin
        yes(v) = RE._rec_rowlike(v)
        @test yes(rows(2)) && yes(rows(500))
        @test yes([(a = 1, b = 2), (a = 1.5, b = 2)])         # same keys, abstract eltype: still rows
        @test !yes([(a = 1, b = 2), (a = 3, c = 4)])          # keys differ: no table to draw
        @test !yes(rows(1))                                   # one row is a record, not a stack
        @test !yes([1, 2, 3]) && !yes((a = 1,)) && !yes(Any[])
        # A row wider than the cap keeps its text form rather than a card nothing can read.
        cols(n) = [NamedTuple{ntuple(i -> Symbol(:c, i), n)}(ntuple(identity, n)) for _ in 1:3]
        @test !yes(cols(RE._REC_ROWS_COLS + 1)) && yes(cols(RE._REC_ROWS_COLS))
    end

    @testset "the stack, and what it is capped at" begin
        h = RE.record_html((; by_nfp = rows(3)))
        @test occursin("srec-rows srec-rows-open", h)
        @test cards(h) == 3
        @test occursin("<span class=\"srec-ci\">1</span>", h)   # each card carries its own index
        @test occursin("<span class=\"srec-ci\">3</span>", h)
        # The cards travel over the websocket and into the memo store on every render, so a long
        # vector ships the head and the header says how many there are.
        big = RE.record_html((; by_nfp = rows(400)))
        @test cards(big) == RE._REC_FAN_CARDS
        @test occursin("400× nfp::Int64, count::Int64", big)
    end

    # `.srec-k` is the click target that asks the hub which expression a FIELD came from. A card's key
    # is a different question, so it must not carry that class: sharing it made every click on a card
    # flash the cell's source.
    @testset "a card's key is not the field click target" begin
        h = RE.record_html((; by_nfp = rows(2)))
        @test count("class=\"srec-k\"", h) == 1                 # the field name, and nothing else
        @test occursin("class=\"srec-ck\">nfp<", h) && occursin("class=\"srec-cv\">", h)
        @test count("data-field=", h) == 1
    end

    @testset "the header says how many and of what" begin
        @test RE._rec_rowtype(@NamedTuple{i::Int64, sq::Int64}) == "i::Int64, sq::Int64"
        # Values of varying type have no per-field type to name, so the keys stand alone. The element
        # type of such a vector is `NamedTuple{(:a, :b)}`, whose `fieldtypes` is `Any` for every
        # column — informative-looking and worth nothing.
        @test RE._rec_rowtype(eltype([(a = 1, b = 2), (a = 1.5, b = 2)])) == "a, b"
        @test RE._rec_rowtype(NamedTuple{(:a, :b)}) == "a, b"
        @test length(RE._rec_rowtype(NamedTuple{ntuple(i -> Symbol(:longfield, i), 8),
                                                NTuple{8,Float64}})) <= 48
        # The full type stays reachable even when the badge is cut.
        h = RE.record_html((; by_nfp = rows(2)))
        @test occursin("title=\"@NamedTuple{nfp::Int64, count::Int64}\"", h)
    end

    # A value inside a card is one line, rounded and short: a card is a fixed-width face, not a place
    # to print a nested structure.
    @testset "a card's values are one short line" begin
        h = RE.record_html((; r = [(name = "x"^80, t = 1.23456789, inner = (p = 1, q = 2)) for _ in 1:2]))
        # Scoped to the card values: the record's `srec-plain` alternative carries the long string in
        # full, so the cap has to be read off the cards themselves.
        cv = [m.captures[1] for m in eachmatch(r"class=\"srec-cv\">([^<]*)", h)]
        @test length(cv) == 6                                      # 2 rows × 3 columns
        @test all(c -> length(c) <= 40 && !occursin('\n', c), cv)
        @test endswith(cv[1], "…") && cv[2] == "1.2346"
        # A nested tuple is its one-line text, not a sub-grid: a card is a fixed-width face.
        @test cv[3] == "(p = 1, q = 2)"
    end

    # Anything the stack declines still shows its CONTENTS: declining must not fall back to the
    # type signature the bounded summary replaced.
    @testset "what the stack declines falls back to the summary" begin
        v = val(RE.record_html((; r = [(a = 1, b = 2), (a = 3, c = 4)])))
        @test occursin("a = 1", v) && !occursin("element Vector", v)
    end
end

@testset "a record carries its plain text too" begin
    h = RE.record_html((; f0 = 1006.63, label = "run 7"))
    @test occursin("srec-grid", h)                       # the grid…
    @test occursin("<pre class=\"srec-plain\">", h)      # …and the text, in one chunk
    plain = match(r"<pre class=\"srec-plain\">(.*?)</pre>"s, h).captures[1]
    @test occursin("f0 = 1006.63", plain)

    @testset "it is escaped, not injected" begin
        p = match(r"<pre class=\"srec-plain\">(.*?)</pre>"s,
                  RE.record_html((; s = "<script>x</script>"))).captures[1]
        @test occursin("&lt;script&gt;", p) && !occursin("<script>", p)
    end

    @testset "and bounded" begin
        # A record may hold a large array; keeping the alternative available must not put that
        # array's whole printed form on the wire.
        p = match(r"<pre class=\"srec-plain\">(.*?)</pre>"s,
                  RE.record_html((; big = collect(1:200_000)))).captures[1]
        @test length(p) <= RE._RECORD_PLAIN_MAX + 8
    end
end

# A colour channel that DECREASES along the ramp is the case to pin: the endpoints are hex
# literals, so they are UInt8, and `0x00 - 0xd6` wraps to 42 rather than going negative. The
# channel then climbs past 255 and prints as a seven-digit hex, which a browser draws as black —
# a matrix thumbnail whose brightest cell came out darkest.
@testset "the matrix ramp stays a valid colour end to end" begin
    @test RE._mat_color(0.0) == "#1e222a"
    @test RE._mat_color(1.0) == "#ffd700"          # the top is gold, not an overflow
    @test all(t -> occursin(r"^#[0-9a-f]{6}$", RE._mat_color(t)), 0:0.001:1)
    @test occursin(r"^#[0-9a-f]{6}$", RE._mat_color(NaN))   # non-finite cells too

    # …and through the SVG: the brightest cell of a gradient must be the ramp's top.
    M = [i * j / 7.0 for i in 1:40, j in 1:30]
    grid, gnr, gnc = RE._matrix_grid(M; max_cells = RE._MAT_MINI_CELLS)
    fills = [m.captures[1] for m in eachmatch(r"fill=\"([^\"]+)\"", RE._mat_svg(grid, gnr, gnc, 46))]
    @test all(f -> occursin(r"^#[0-9a-f]{6}$", f), fills)
    @test last(fills) == "#ffd700"
end

@testset "a vector field shows its items, not its summary line" begin
    h = RE.record_html((; modules = ["gcc-native/14", "cray-mpich/9.1.0"], tags = [:a, :b]))
    @test occursin("<span class=\"srec-item\">gcc-native/14</span>", h) && occursin(">:a<", h)
    @test !occursin("2-element", h)
    @test occursin(">[1, 2, 3]<", RE.record_html((; v = [1, 2, 3])))
    long = RE.record_html((; v = string.(1:100)))
    @test occursin("… 60 more", long) && count("srec-item", long) == 40
    @test occursin(">empty<", RE.record_html((; v = String[])))
end
