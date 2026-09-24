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
    f = try; Float64(x); catch; return nothing; end
    isfinite(f) || return string(f)
    return string(round(f; sigdigits = 5))
end
# The compact one-line text of a value, rounded and capped.
function _rec_text(v)
    s = try
        sprint((io, x) -> show(IOContext(io, :compact => true, :limit => true), MIME"text/plain"(), x), v)
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

function _rec_value_html(io::IO, v, depth::Int)
    if v isa NamedTuple && !isempty(v) && depth < _RECORD_MAX_DEPTH
        _record_fields(io, v, depth + 1)
        return
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

function _record_fields(io::IO, nt::NamedTuple, depth::Int)
    print(io, "<div class=\"srec-grid\">")
    ks = keys(nt)
    for (i, k) in enumerate(ks)
        i > _RECORD_MAX_FIELDS && (print(io, "<div class=\"srec-more\">+", length(ks) - _RECORD_MAX_FIELDS, " more</div>"); break)
        v = nt[k]
        nested = v isa NamedTuple && !isempty(v) && depth < _RECORD_MAX_DEPTH
        print(io, "<div class=\"srec-f", nested ? " srec-nest" : "", "\"><span class=\"srec-k\">", _rec_esc(string(k)), "</span>")
        _rec_value_html(io, v, depth)
        print(io, "</div>")
    end
    print(io, "</div>")
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
    print(io, "</div>")
    return String(take!(io))
end
