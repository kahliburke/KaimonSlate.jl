# ── A NamedTuple as a record ─────────────────────────────────────────────────────────────────
# `(; f0, ζ)` is how a cell says "these are the numbers I produced", and its text `show` is a
# single line of sixteen-digit floats with the units buried in it. It renders instead as a grid of
# fields: the name small above its value, the number to five significant figures, a unit split off
# and dimmed beside it, an uncertainty set smaller after the `±`, a nested NamedTuple as a titled
# sub-grid, and a value with its own Slate rendering (a requirement's badge) shown as that.
#
# Generic by construction: nothing here knows a units or uncertainty package. A value is read from
# its compact one-line `show`, which is where those packages put what they mean.
# Shared by the engine and the worker, like capture.jl, so Base only.

const _RECORD_MAX_FIELDS = 60
const _RECORD_MAX_DEPTH = 3
const _RECORD_SLATE_HTML = "application/vnd.kaimonslate.html+html"

_rec_esc(s) = replace(String(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")
# Every decimal in a text rounded to five significant figures, with a trailing `.0` kept only on
# whole numbers the text wrote that way.
_rec_round(s::AbstractString) = replace(s, r"-?\d+\.\d+(?:e[-+]?\d+)?" => m -> (x = tryparse(Float64, m); x === nothing ? m : string(round(x; sigdigits = 5))))
function _rec_number(x::Real)
    x isa Bool && return string(x)
    x isa Integer && return string(x)
    # An exact type keeps its own notation. Rounding a Rational to five significant figures turns
    # `22//7` into `3.1429` and throws away the one property it was chosen for.
    x isa Rational && return string(x)
    f = try; Float64(x); catch; return nothing; end
    isfinite(f) || return string(f)
    return string(round(f; sigdigits = 5))
end
# A container's `text/plain` form is a HEADER line followed by its elements, so the first-line cut
# below reduced it to the type and none of the data — a field holding eight rows read as
# `8-element Vector{@NamedTuple{nfp::Int64, count::Int64}}:`. The two-argument `show` puts the
# elements inline instead.
#
# Taken from the first few elements rather than from the whole container, because the cap at the end
# of `_rec_text` cannot undo the cost of building the string: a million-element vector would be
# rendered in full and then thrown away. A container small enough to show whole is shown whole, which
# also keeps its own delimiters (`Dict(…)`, `Set(…)`) instead of a Vector's brackets.
# `_REC_SEQ_MAX` is under `_rec_text`'s own 140-char cap on purpose: the "… N total]" tail is the most
# useful part of a summary, and letting the cap fall through the middle of it loses the count and
# leaves a mangled bracket. Fit fewer elements instead.
const _REC_SEQ_HEAD = 6
const _REC_SEQ_MAX = 110
function _rec_seq_text(v)
    n = length(v)
    show1(x) = sprint((io, y) -> show(IOContext(io, :compact => true, :limit => true), y), x)
    if n <= _REC_SEQ_HEAD
        whole = show1(v)
        length(whole) <= _REC_SEQ_MAX && return whole
    end
    k, used = 0, 0
    for x in Iterators.take(v, _REC_SEQ_HEAD)
        used += length(show1(x)) + 2                      # ", " between elements
        used > _REC_SEQ_MAX && break
        k += 1
    end
    head = collect(Iterators.take(v, max(k, 1)))
    body = chop(show1(head))                              # drop the closing bracket to extend it
    return length(head) < n ? string(body, ", … ", n, " total]") : string(body, "]")
end

# ── Rows of the same shape ───────────────────────────────────────────────────
# A vector of NamedTuples sharing their keys is a TABLE, and it arrived here as a line of text —
# `[(nfp = 1, count = 3), (nfp = 2, count = 6), …]` — which is the shape of the data spelled out
# rather than shown. It renders as a stack instead: the FIRST row face-up with its own values, the
# rest suggested behind it, and the whole table in a `<template>` that a click swaps in.
#
# The expanded form rides along rather than being fetched, as the matrix thumbnail's does: opening
# costs no round-trip and the table cannot disagree with the face-up row. Both are capped, because
# this markup crosses a websocket and lands in the memo store on every render.
# More than fits beside the field, because the fan scrolls — but still bounded: this markup crosses
# a websocket and lands in the memo store on every render, so the rest stay a count.
const _REC_FAN_CARDS = 12
const _REC_ROWS_COLS = 8          # columns per card; a wider row keeps its text form
# Whether the rows share a shape is answered by the ELEMENT TYPE, in constant time — nothing here
# walks the vector. `fieldnames` is the test itself: it returns the keys when they are fixed by the
# type and throws when they are not, so `[(a=1,b=2), (a=3,c=4)]` is declined while
# `[(a=1,b=2), (a=1.5,b=2)]` — same keys, different value types, so NOT a concrete eltype — is
# accepted. Asking `isconcretetype` instead turned that second case away for no reason.
function _rec_rowlike(v)
    (v isa AbstractVector && length(v) > 1 && eltype(v) <: NamedTuple) || return false
    ks = try; fieldnames(eltype(v)); catch; return false; end
    return length(ks) in 1:_REC_ROWS_COLS
end

# `i::Int64, sq::Int64` for a concrete row type, or just the names when the values' types vary.
# Capped: this sits in a one-line header, and the whole thing is on the element's `title` anyway.
function _rec_rowtype(T)
    ks = fieldnames(T)
    ts = try; fieldtypes(T); catch; (); end
    # A vector of rows whose VALUE types vary has no value types in its element type, and `fieldtypes`
    # answers `Any` for every column rather than declining. `a::Any, b::Any` says less than `a, b`.
    named = length(ts) == length(ks) && !all(==(Any), ts)
    s = named ? join((string(k, "::", t) for (k, t) in zip(ks, ts)), ", ") : join(ks, ", ")
    return length(s) > 48 ? first(s, 47) * "…" : s
end

_rec_cell_text(x) = (s = x isa Real ? something(_rec_number(x), string(x)) :
                         x isa AbstractString ? String(x) : _rec_text(x);
                     length(s) > 40 ? first(s, 39) * "…" : s)

function _rec_card(io::IO, r, ks, i::Int)
    # The row's own index. Gathered you see only the top card's, so it reads as "this is the first";
    # fanned it is how you keep your place along the strip.
    print(io, "<span class=\"srec-card\"><span class=\"srec-ci\">", i, "</span>")
    for k in ks
        # `srec-ck`/`srec-cv`, NOT the field classes: `.srec-k` is the click target that asks the hub
        # where a field came from, and a card's key is a different question. Reusing the class made
        # every click on a card flash the cell source.
        print(io, "<span class=\"srec-rc\"><span class=\"srec-ck\">", _rec_esc(String(k)),
                  "</span><span class=\"srec-cv\">", _rec_esc(_rec_cell_text(getfield(r, k))), "</span></span>")
    end
    print(io, "</span>")
end

function _rec_rows_html(io::IO, v::AbstractVector, field::AbstractString)
    ks = fieldnames(eltype(v))
    print(io, "<span class=\"srec-rows srec-rows-open\" data-rowsfield=\"", _rec_esc(field),
              "\" title=\"click to fan out\">")
    for (i, r) in enumerate(Iterators.take(v, _REC_FAN_CARDS))
        _rec_card(io, r, ks, i)
    end
    print(io, "</span>")
    return true
end

# The compact one-line text of a value, rounded and capped.
function _rec_text(v)
    s = try
        if v isa Union{AbstractArray,AbstractSet,AbstractDict} && !isempty(v)
            _rec_seq_text(v)
        else
            sprint((io, x) -> show(IOContext(io, :compact => true, :limit => true), MIME"text/plain"(), x), v)
        end
    catch
        try; repr(v); catch; string(typeof(v)); end
    end
    s = first(split(s, '\n'))
    s = _rec_round(s)
    return length(s) > 140 ? first(s, 139) * "…" : s
end

# `1006.6 Hz` → ("1006.6", "", "Hz"); `(1007.0 ± 71.0) Hz` → ("1007.0", "71.0", "Hz"); anything that
# is not a number with an optional uncertainty and a short unit → nothing.
const _REC_NUM_UNIT = r"^\(?(-?\d[\d.]*(?:e[-+]?\d+)?)(?:\s*±\s*(\d[\d.]*(?:e[-+]?\d+)?))?\)?(?:\s+(.+))?$"
function _rec_split(s::AbstractString)
    m = match(_REC_NUM_UNIT, s)
    m === nothing && return nothing
    unit = m.captures[3] === nothing ? "" : String(m.captures[3])
    (length(unit) > 24 || occursin(r"[()\[\]{}=,\"]", unit)) && return nothing
    return (String(m.captures[1]), m.captures[2] === nothing ? "" : String(m.captures[2]), unit)
end

# ── Common units ───────────────────────────────────────────────────────────────────────────────
# A units package working in SI prints a quantity in base units: 432 MW reads `4.3247e8 m² kg s⁻³`.
# The dimension is matched against the named units a reader expects and the number given the SI
# prefix that puts it between 1 and 1000, so that reads `432.47 MW`. Text in, text out: nothing
# here depends on a units package, only on the base-unit notation `m`, `kg`, `s`, `A`, `K`, `mol`,
# `cd` with superscript or `^` exponents. A unit that is not in base units, or a dimension with no
# common name, is left as it was.
const _SI_BASE = ("m", "kg", "s", "A", "K", "mol", "cd")
# (m, kg, s, A, K, mol, cd) → the unit's symbol. A symbol with `/` takes its prefix on the first part.
const _NAMED_UNITS = Dict{NTuple{7,Int},String}(
    (2, 1, -3, 0, 0, 0, 0) => "W",   (0, 1, -3, 0, 0, 0, 0) => "W/m²", (2, 1, -2, 0, 0, 0, 0) => "J",
    (1, 1, -2, 0, 0, 0, 0) => "N",   (-1, 1, -2, 0, 0, 0, 0) => "Pa",  (0, 0, -1, 0, 0, 0, 0) => "Hz",
    (2, 1, -3, -1, 0, 0, 0) => "V",  (2, 1, -3, -2, 0, 0, 0) => "Ω",   (-2, -1, 3, 2, 0, 0, 0) => "S",
    (-2, -1, 4, 2, 0, 0, 0) => "F",  (2, 1, -2, -2, 0, 0, 0) => "H",   (0, 0, 1, 1, 0, 0, 0) => "C",
    (0, 1, -2, -1, 0, 0, 0) => "T",  (2, 1, -2, -1, 0, 0, 0) => "Wb",  (1, 0, 0, 0, 0, 0, 0) => "m",
    (0, 0, 1, 0, 0, 0, 0) => "s",    (0, 0, 0, 1, 0, 0, 0) => "A",     (0, 0, 0, 0, 1, 0, 0) => "K",
    (1, 0, -1, 0, 0, 0, 0) => "m/s", (1, 0, -2, 0, 0, 0, 0) => "m/s²", (0, 1, -1, 0, 0, 0, 0) => "kg/s",
    (3, 0, -1, 0, 0, 0, 0) => "m³/s", (-3, 1, 0, 0, 0, 0, 0) => "kg/m³", (2, 0, 0, 0, 0, 0, 0) => "m²",
    (3, 0, 0, 0, 0, 0, 0) => "m³")
# Units whose prefix scales the number (not `m²`, `kg/m³`, …, which a prefix would square or split).
const _PREFIXABLE = Set(["W", "W/m²", "J", "N", "Pa", "Hz", "V", "Ω", "S", "F", "H", "C", "T", "Wb", "m", "s", "A"])
const _PREFIX_OF = Dict(-12 => "p", -9 => "n", -6 => "μ", -3 => "m", 0 => "", 3 => "k", 6 => "M", 9 => "G", 12 => "T")
const _SUPER = Dict('⁰' => '0', '¹' => '1', '²' => '2', '³' => '3', '⁴' => '4', '⁵' => '5', '⁶' => '6', '⁷' => '7', '⁸' => '8', '⁹' => '9', '⁻' => '-')

# `m² kg s⁻³` → (2, 1, -3, 0, 0, 0, 0), or nothing when a token is not a base unit.
function _si_dims(unit::AbstractString)
    d = zeros(Int, 7)
    toks = split(strip(unit))
    isempty(toks) && return nothing
    for t in toks
        m = match(r"^([A-Za-z]+)(?:\^?\(?(-?\d+)\)?|([⁻⁰¹²³⁴⁵⁶⁷⁸⁹]+))?$", t)
        m === nothing && return nothing
        i = findfirst(==(m.captures[1]), _SI_BASE)
        i === nothing && return nothing
        e = m.captures[2] !== nothing ? parse(Int, m.captures[2]) :
            m.captures[3] !== nothing ? parse(Int, String(map(c -> _SUPER[c], collect(m.captures[3])))) : 1
        d[i] += e
    end
    return Tuple(d)
end

"""
    common_units(num, err, unit) -> (num, err, unit)

A number (and its uncertainty) in SI base units, rewritten in the common unit its dimension has,
with the SI prefix that puts it between 1 and 1000: `("4.3247e8", "", "m² kg s⁻³")` becomes
`("432.47", "", "MW")`. Returned unchanged when the unit is not in base units or has no name.
"""
function common_units(num::AbstractString, err::AbstractString, unit::AbstractString)
    dims = _si_dims(unit)
    dims === nothing && return (num, err, unit)
    name = get(_NAMED_UNITS, dims, nothing)
    name === nothing && return (num, err, unit)
    v = tryparse(Float64, num)
    v === nothing && return (num, err, unit)
    e = tryparse(Float64, err)
    p = 0
    if name in _PREFIXABLE && v != 0 && isfinite(v)
        p = clamp(3 * floor(Int, log10(abs(v)) / 3), -12, 12)
    end
    s = 10.0^p
    f(x) = string(round(x / s; sigdigits = 5))
    return (f(v), e === nothing ? err : f(e), _PREFIX_OF[p] * name)
end

"""
    common_units_text(text) -> String

The same for a whole quantity's text: `"(1.59e9 ± 2.0e7) m² kg s⁻³"` becomes `"1590.0 ± 20.0 MW"`.
Text that is not a number with a base-unit dimension comes back as it was.
"""
function common_units_text(text::AbstractString)
    parts = _rec_split(_rec_round(String(text)))
    parts === nothing && return String(text)
    num, err, unit = common_units(parts...)
    isempty(unit) && return String(text)
    return num * (isempty(err) ? "" : " ± " * err) * " " * unit
end

# ── A matrix field ─────────────────────────────────────────────────────────────────────────────
# The downsampling is NOT redone here: `_matrix_grid` (slate_matrix.jl, included above) already
# block-averages a dense matrix, walks CSC storage directly for a sparse one, and reads only
# `dv`/`ev` for a SymTridiagonal — so a matrix with a side in the tens of thousands costs its
# structure, not its area. This adds only the one thing slate_matrix has no form of: a STATIC
# picture. Its own renderings are an ECharts instance or KaTeX, and a record field can host
# neither, so the grid is painted as an inline SVG that needs nothing to boot and survives
# export, PDF and html2canvas. Clicking the field asks for the real `slate_matrix` rendering.
const _MAT_MINI_CELLS = 18 * 18   # `max_cells` for the field-sized thumbnail
const _MAT_FULL_CELLS = 64 * 64   # …and for the expanded view behind a click
const _MAT_LEVELS = 24            # ramp steps — quantised so equal neighbours merge into one rect
const _MAT_MINI_BYTES = 3_000     # markup ceilings the grid is coarsened to meet (`_mat_svg_capped`)
const _MAT_FULL_BYTES = 24_000

# The ramp `_matrix_heatmap` uses, resolved to a concrete fill (ECharts interpolates its own).
function _mat_color(t::Float64)
    isfinite(t) || return "#3a3f4b"
    t = clamp(t, 0.0, 1.0)
    lo, mid, hi = (0x1e, 0x22, 0x2a), (0x56, 0x9c, 0xd6), (0xff, 0xd7, 0x00)
    a, b, u = t < 0.5 ? (lo, mid, t * 2) : (mid, hi, (t - 0.5) * 2)
    # Widened to Int first: a hex literal is a UInt8, and blue DECREASES from mid to hi, so
    # `0x00 - 0xd6` wraps to 42 instead of going negative. The channel then climbs to 256, which
    # prints as a seven-digit hex that a browser cannot parse and draws as black.
    ch(i) = round(Int, Int(a[i]) + (Int(b[i]) - Int(a[i])) * u)
    return string("#", string(ch(1); base = 16, pad = 2), string(ch(2); base = 16, pad = 2),
                  string(ch(3); base = 16, pad = 2))
end

# One `<rect>` per cell is too verbose for something that crosses a websocket on every render, so
# the ramp is quantised and each row's equal neighbours merge into a single rect.
function _mat_svg(grid::AbstractMatrix{Float64}, gnr::Int, gnc::Int, px::Int)
    (gnr == 0 || gnc == 0) && return ""
    lo, hi = Inf, -Inf
    for v in grid
        isfinite(v) || continue
        v < lo && (lo = v); v > hi && (hi = v)
    end
    span = (isfinite(lo) && isfinite(hi) && hi > lo) ? hi - lo : 1.0
    lev(v) = isfinite(v) ? clamp(round(Int, (v - lo) / span * (_MAT_LEVELS - 1)), 0, _MAT_LEVELS - 1) : -1
    h = max(round(Int, px * gnr / max(gnc, 1)), 1)
    io = IOBuffer()
    print(io, "<svg class=\"srec-mat-svg\" viewBox=\"0 0 ", gnc, " ", gnr, "\" width=\"", px, "\" height=\"", h,
              "\" preserveAspectRatio=\"none\" shape-rendering=\"crispEdges\">")
    for i in 1:gnr
        j = 1
        while j <= gnc
            k = j
            while k < gnc && lev(grid[i, k + 1]) == lev(grid[i, j]); k += 1; end
            l = lev(grid[i, j])
            print(io, "<rect x=\"", j - 1, "\" y=\"", i - 1, "\" width=\"", k - j + 1, "\" height=\"1\" fill=\"",
                      l < 0 ? _mat_color(NaN) : _mat_color(l / (_MAT_LEVELS - 1)), "\"/>")
            j = k + 1
        end
    end
    print(io, "</svg>")
    return String(take!(io))
end

_mat_label(M::AbstractMatrix) = first(try; summary(M); catch; string(size(M, 1), "×", size(M, 2)); end, 90)

# Run-merging is data-dependent — a diagonal or a gradient collapses, uncorrelated noise does not
# — so resolution cannot be the guarantee and SIZE has to be: coarsen the grid until the markup
# fits. A record's output crosses a websocket and lands in the memo store on every render, so a
# preview that is merely usually-small is not good enough.
function _mat_svg_capped(M::AbstractMatrix, max_cells::Int, px::Int, maxbytes::Int)
    cells = max_cells
    while true
        grid, gnr, gnc = Base.invokelatest(_matrix_grid, M; max_cells = cells)
        s = _mat_svg(grid, gnr, gnc, px)
        (length(s) <= maxbytes || cells <= 64) && return s
        cells = max(64, cells ÷ 4)
    end
end

function _rec_matrix_html(io::IO, M::AbstractMatrix, field::AbstractString)
    svg = _mat_svg_capped(M, _MAT_MINI_CELLS, 46, _MAT_MINI_BYTES)
    isempty(svg) && return false
    # The expanded view rides along in a <template> at a larger grid, from the SAME `_matrix_grid`
    # — so opening it costs no round-trip and the picture cannot disagree with the thumbnail.
    # `data-matfield` names the field for anything that later wants the value itself.
    big = _mat_svg_capped(M, _MAT_FULL_CELLS, 360, _MAT_FULL_BYTES)
    print(io, "<span class=\"srec-mat srec-mat-open\" data-matfield=\"", _rec_esc(field), "\" title=\"",
              _rec_esc(_mat_label(M)), " — click to open\">", svg,
              "<span class=\"srec-mat-cap\">", _rec_esc(string(size(M, 1), "×", size(M, 2))), "</span>")
    isempty(big) || print(io, "<template class=\"srec-mat-full\" data-label=\"",
                              _rec_esc(_mat_label(M)), "\">", big, "</template>")
    print(io, "</span>")
    return true
end

# How many items a list field shows before saying how many more there are.
const _REC_VEC_ITEMS = 40

# A vector of names (strings, symbols) as a list of items, which reads better than the quoted text a
# summary gives: module lists, tags. Any other collection takes the summary (`_rec_seq_text`).
function _rec_vector_html(io::IO, v::AbstractVector)
    n = length(v)
    shown = n > _REC_VEC_ITEMS ? v[firstindex(v):firstindex(v) + _REC_VEC_ITEMS - 1] : v
    more = n - length(shown)
    print(io, "<span class=\"srec-list\">")
    isempty(v) && print(io, "<span class=\"srec-v srec-text\">empty</span>")
    for x in shown
        t = x isa Symbol ? ":" * String(x) : string(x)
        print(io, "<span class=\"srec-item\">", _rec_esc(length(t) > 80 ? first(t, 79) * "…" : t), "</span>")
    end
    more > 0 && print(io, "<span class=\"srec-more\">… ", more, " more</span>")
    print(io, "</span>")
    return nothing
end

function _rec_value_html(io::IO, v, depth::Int, field::AbstractString)
    if v isa NamedTuple && !isempty(v) && depth < _RECORD_MAX_DEPTH
        _record_fields(io, v, depth + 1, field)
        return
    end
    # Rows of the same shape are a table, so they are shown as one rather than as a line of text.
    # Built into a buffer first: `_rec_rows_html` writes as it goes, so a throw partway through would
    # leave half a stack behind AND then fall through to print the text form underneath it.
    if _rec_rowlike(v)
        buf = IOBuffer()
        if (try _rec_rows_html(buf, v, field) catch; false end)
            print(io, String(take!(buf)))
            return
        end
    end
    # A matrix shows its shape AS a shape, not as `4×3 Matrix{Float64}`. Complex goes through too:
    # `_matrix_grid` takes `real` itself, the same view its ECharts heatmap gives.
    if v isa AbstractMatrix && eltype(v) <: Number && !isempty(v)
        (try _rec_matrix_html(io, v, field) catch; false end) && return
    end
    # A value that renders itself for Slate (a requirement's badge, a component) is shown as that.
    if !(v isa Number || v isa AbstractString || v isa Symbol)
        html = try
            Base.invokelatest(showable, MIME(_RECORD_SLATE_HTML), v) ?
                String(Base.invokelatest(sprint, show, MIME(_RECORD_SLATE_HTML), v)) : nothing
        catch
            nothing
        end
        if html !== nothing
            print(io, "<div class=\"srec-rich\">", html, "</div>")
            return
        end
    end
    if v isa Bool
        print(io, "<span class=\"srec-v srec-bool ", v ? "yes" : "no", "\">", v ? "true" : "false", "</span>")
        return
    end
    # A vector of names shows its items, one each.
    if v isa AbstractVector && (eltype(v) <: Union{AbstractString,Symbol} ||
                                (!isempty(v) && all(x -> x isa Union{AbstractString,Symbol}, v)))
        _rec_vector_html(io, v)
        return
    end
    if v isa AbstractString
        print(io, "<span class=\"srec-v srec-str\">", _rec_esc(length(v) > 140 ? first(v, 139) * "…" : v), "</span>")
        return
    end
    n = v isa Real ? _rec_number(v) : nothing
    parts = n !== nothing ? (n, "", "") : _rec_split(_rec_text(v))
    if parts === nothing
        print(io, "<span class=\"srec-v srec-text\">", _rec_esc(_rec_text(v)), "</span>")
        return
    end
    num, err, unit = isempty(parts[3]) ? parts : common_units(parts...)
    print(io, "<span class=\"srec-v\">", _rec_esc(num))
    isempty(err) || print(io, "<span class=\"srec-err\"> ± ", _rec_esc(err), "</span>")
    isempty(unit) || print(io, "<span class=\"srec-u\">", _rec_esc(unit), "</span>")
    print(io, "</span>")
end

function _record_fields(io::IO, nt::NamedTuple, depth::Int, path::AbstractString = "")
    print(io, "<div class=\"srec-grid\">")
    ks = keys(nt)
    for (i, k) in enumerate(ks)
        i > _RECORD_MAX_FIELDS && (print(io, "<div class=\"srec-more\">+", length(ks) - _RECORD_MAX_FIELDS, " more</div>"); break)
        v = nt[k]
        nested = v isa NamedTuple && !isempty(v) && depth < _RECORD_MAX_DEPTH
        # The dotted path from the record's root, so a click on a nested field can name the value
        # it came from (`fit.coeffs`) when it asks for the full rendering.
        sub = isempty(path) ? string(k) : string(path, '.', k)
        print(io, "<div class=\"srec-f", nested ? " srec-nest" : "", "\" data-field=\"", _rec_esc(sub),
                  "\"><span class=\"srec-k\">", _rec_esc(string(k)))
        # Count AND element type, so the header says how many and of what — a stack of cards shows
        # the keys but not what is holding them, which is the difference between rows of NamedTuples
        # and rows of some struct once this covers more than NamedTuples.
        #
        # Inside the name span, not beside it: `.srec-f` is a column flex, so a sibling would take a
        # line of its own — and a record grid stretches every field in a row to the tallest, so one
        # extra line is paid for by every sibling card in that row.
        if _rec_rowlike(v)
            print(io, "<span class=\"srec-n\" title=\"", _rec_esc(string(eltype(v))), "\">",
                      length(v), "\u00d7 ", _rec_esc(_rec_rowtype(eltype(v))), "</span>")
        end
        print(io, "</span>")
        _rec_value_html(io, v, depth, sub)
        print(io, "</div>")
    end
    print(io, "</div>")
end

# ── Keeping the record's value, so a field can be asked about later ────────────────────────────
# The rendered grid is HTML: its numbers are text and its matrices are thumbnails. Opening a field
# in its real `slate_matrix` form needs the VALUE, and a cell's value is anonymous unless the cell
# assigned it. So the record keeps the last one per cell, and a lookup walks the dotted field path
# the grid already labels each field with.
#
# Bounded and ordered: a record can hold large arrays, and holding every cell's forever would make
# viewing a notebook a memory leak. The oldest entry goes when the bound is reached; a miss simply
# means the popup asks for a value no longer held, which the caller reports rather than guesses at.
const _RECORD_KEEP = 24
const _RECORD_CACHE = Dict{String,Any}()
const _RECORD_ORDER = String[]
const _RECORD_LOCK = ReentrantLock()

function record_remember!(cellid::AbstractString, nt::NamedTuple)
    isempty(cellid) && return nt
    lock(_RECORD_LOCK) do
        id = String(cellid)
        haskey(_RECORD_CACHE, id) || push!(_RECORD_ORDER, id)
        _RECORD_CACHE[id] = nt
        while length(_RECORD_ORDER) > _RECORD_KEEP
            delete!(_RECORD_CACHE, popfirst!(_RECORD_ORDER))
        end
    end
    return nt
end

"Walk `a.b.c` from the record kept for `cellid`. `nothing` when the cell or the path is unknown."
function record_field(cellid::AbstractString, path::AbstractString)
    v = lock(_RECORD_LOCK) do; get(_RECORD_CACHE, String(cellid), nothing); end
    v === nothing && return nothing
    for part in split(String(path), '.'; keepempty = false)
        k = Symbol(part)
        (v isa NamedTuple && haskey(v, k)) || return nothing
        v = v[k]
    end
    return v
end

# The NamedTuple as Julia would have shown it, for the reader who wants the text back. Bounded the
# same way the fields are: a record holding a large array must not put that array's whole printed
# form on the wire just to keep the alternative available.
const _RECORD_PLAIN_MAX = 4_000
function _rec_plain(nt::NamedTuple)
    s = try
        sprint((io, x) -> show(IOContext(io, :limit => true, :compact => true,
                                         :displaysize => (24, 120)), MIME"text/plain"(), x), nt)
    catch
        try; repr(nt); catch; string(typeof(nt)); end
    end
    return length(s) > _RECORD_PLAIN_MAX ? first(s, _RECORD_PLAIN_MAX) * "\n…" : s
end

"""
    record_matrix_render(cell, field) -> Dict

One matrix field of a cell's remembered record, rendered by `slate_matrix` — the SAME renderer a
bare matrix gets, not a second-best built for the grid. So the popup shows an ECharts heatmap or
the KaTeX form exactly as that matrix's size and structure warrant.

`{kind = "echart", option}` or `{kind = "latex", tex}`, plus `label`; `{error}` when the value is no
longer held (the cache is bounded) or the path names no matrix. Lives here so the gate worker and
an in-process kernel answer the request with one implementation.
"""
function record_matrix_render(cell::AbstractString, field::AbstractString)
    v = try; record_field(cell, field); catch; nothing; end
    v === nothing && return Dict{String,Any}("error" => "that value is no longer available — re-run the cell")
    v isa AbstractMatrix || return Dict{String,Any}("error" => "field '$field' is not a matrix")
    r = try
        Base.invokelatest(slate_matrix, v)
    catch e
        return Dict{String,Any}("error" => first(sprint(showerror, e), 200))
    end
    label = try; first(summary(v), 90); catch; ""; end
    # An EChart carries its spec in `.option`; the KaTeX forms render through `text/latex`. Tested
    # by shape rather than by type, because `EChart` is declared by each host, not by this file.
    hasproperty(r, :option) &&
        return Dict{String,Any}("kind" => "echart", "option" => getproperty(r, :option), "label" => label)
    tex = try
        sprint((io, x) -> show(io, MIME"text/latex"(), x), r)
    catch e
        return Dict{String,Any}("error" => first(sprint(showerror, e), 200))
    end
    return Dict{String,Any}("kind" => "latex", "tex" => tex, "label" => label)
end

"""
    record_html(nt::NamedTuple) -> String | nothing

The HTML a NamedTuple cell value renders as: a grid of its fields, each value formatted for
reading (see the notes at the top of this file). `nothing` for an empty one, which keeps its text.
"""
function record_html(nt::NamedTuple)
    isempty(nt) && return nothing
    io = IOBuffer()
    print(io, "<div class=\"slate-record\">")
    _record_fields(io, nt, 0)
    # The plain text rides along so the reader can switch back to it. It has to be HERE rather than
    # left to the text repr beside the cell: that one is dropped wherever richer output exists
    # (`_cell_view`), so a preference built on it would work live and show an empty cell in an
    # export. Carrying both inside the chunk makes the choice one CSS class, everywhere.
    print(io, "<pre class=\"srec-plain\">", _rec_esc(_rec_plain(nt)), "</pre>")
    print(io, "</div>")
    return String(take!(io))
end
