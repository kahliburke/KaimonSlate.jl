# Server-side table cell RENDERER — the Julia half of the dual formatter. The JS mirror is
# `fmtCell` in assets/js/core.js; the two MUST agree (guarded by the golden fixture
# test/fixtures/format_cases.json, asserted from both languages). Table VALUES ship RAW over the
# wire (numbers stay numeric so the browser sorts them numerically); this stringifies a cell only at
# render time, from a serializable `ColumnFormat`/wire-Dict spec. Only the static exporters
# (HTML + Typst, `_export_table_html` / `_typst_table`) call it — the live table formats in JS.
#
# Rounding is the top divergence risk (Julia `round` is banker's; JS `toFixed` is inconsistent), so
# rounding + grouping are HAND-IMPLEMENTED here and mirrored step-for-step in JS: round-half-away-
# from-zero via `floor(abs(x)*10^d + 0.5)`, then decimal + thousands assembly by hand.

# Read a field from either a `ColumnFormat` or the wire `Dict` (exports read specs back as Dicts).
_fmt_field(f::ColumnFormat, k::Symbol) = getfield(f, k)
_fmt_field(d::AbstractDict, k::Symbol) = haskey(d, String(k)) ? d[String(k)] : get(d, k, nothing)

# Coerce a reduced cell value to a Float64, or `nothing` if it isn't a formattable number. `Bool` is
# NOT a number here (a bool column with a numeric format falls through to its raw text).
_as_number(x::Bool) = nothing
_as_number(x::Real) = (f = Float64(x); isfinite(f) ? f : nothing)
_as_number(x::AbstractString) = (n = tryparse(Float64, x); (n !== nothing && isfinite(n)) ? n : nothing)
_as_number(::Any) = nothing

# Round |x| to `d` decimals half-away-from-zero and return `(negative, integer-units::BigInt)` where
# units = round(|x| * 10^d). BigInt keeps large grouped integers exact.
function _round_units(x::Float64, d::Int)
    y = abs(x) * (10.0^d)
    return (x < 0, BigInt(floor(y + 0.5)))
end

# Plain decimal string of `x` at `d` decimals (no grouping), sign preserved. `d==0` ⇒ integer.
function _round_dec(x::Float64, d::Int)
    neg, u = _round_units(x, d)
    s = string(u)
    if d > 0
        s = lpad(s, d + 1, '0')               # guarantee an integer digit before the point
        s = s[1:end-d] * "." * s[end-d+1:end]
    end
    return (neg && u != 0) ? "-" * s : s
end

# Group the integer part of a decimal string in threes (keeps sign + fractional part).
function _group3(dec::AbstractString)
    neg = startswith(dec, "-"); body = neg ? SubString(dec, 2) : SubString(dec, 1)
    dot = findfirst('.', body)
    ip = dot === nothing ? body : SubString(body, 1, dot - 1)
    rest = dot === nothing ? "" : SubString(body, dot)
    n = length(ip); io = IOBuffer()
    for (i, ch) in enumerate(ip)
        (i > 1 && (n - i + 1) % 3 == 0) && print(io, ',')
        print(io, ch)
    end
    return (neg ? "-" : "") * String(take!(io)) * rest
end
_maybe_group(dec::AbstractString, sep::Bool) = sep ? _group3(dec) : String(dec)

# Scientific: mantissa at `sig` significant figures, integer exponent — `1.23e4`, `1.20e-3`.
function _sci(x::Float64, sig::Int)
    x == 0 && return "0e0"
    neg = x < 0; ax = abs(x)
    e = floor(Int, log10(ax))
    m = ax / (10.0^e)
    ms = _round_dec(m, max(sig - 1, 0))
    if tryparse(Float64, ms) !== nothing && parse(Float64, ms) >= 10.0   # rounding pushed 9.99→10.0
        e += 1
        ms = _round_dec(m / 10.0, max(sig - 1, 0))
    end
    return (neg ? "-" : "") * ms * "e" * string(e)
end

# 1024-base humanized size; `B` shows no decimals.
const _BYTE_UNITS = ("B", "KB", "MB", "GB", "TB", "PB")
function _bytes(x::Float64, d::Int)
    neg = x < 0; ax = abs(x); i = 1
    while ax >= 1024 && i < length(_BYTE_UNITS); ax /= 1024; i += 1; end
    body = _round_dec(ax, i == 1 ? 0 : d)
    return (neg ? "-" : "") * body * " " * _BYTE_UNITS[i]
end

"""
    _format_cell(value, fmt) -> String

Render one reduced cell `value` under a column format `fmt` (a `ColumnFormat`, the wire `Dict`, or
`nothing`). `nothing`/`missing` ⇒ `""`; a non-numeric value in a formatted column ⇒ its raw string
(so a stray text cell never breaks). Mirror of JS `fmtCell`.
"""
# Default (no explicit format): a CLEAN render — integers as-is; an integer-valued float without a
# trailing `.0` (210000.0 → "210000", 1.25e6 → "1250000"); other floats via the shortest repr. This
# mirrors what the browser shows for a raw JSON number (`String(n)`), so the live table and the static
# exports agree on the default. (Conservative: no thousands separators / % / currency unless opted in.)
_clean_default(::Nothing) = ""
_clean_default(::Missing) = ""
_clean_default(v::Bool) = string(v)
_clean_default(v::Integer) = string(v)
function _clean_default(v::AbstractFloat)
    isfinite(v) || return string(v)
    (v == round(v) && abs(v) < 1e15) && return string(Integer(round(v)))
    return string(v)
end
_clean_default(v) = string(v)
_format_cell(value, ::Nothing) = _clean_default(value)
function _format_cell(value, fmt)
    (value === nothing || value === missing) && return ""
    n = _as_number(value)
    n === nothing && return string(value)
    kind = Symbol(something(_fmt_field(fmt, :kind), :fixed))
    digits = _fmt_field(fmt, :digits)
    sep = _fmt_field(fmt, :sep) === true
    prefix = something(_fmt_field(fmt, :prefix), "")
    suffix = something(_fmt_field(fmt, :suffix), "")
    body =
        kind === :integer    ? _maybe_group(_round_dec(n, 0), sep) :
        kind === :percent     ? _round_dec(n * 100, digits === nothing ? 1 : digits) * "%" :
        kind === :currency    ? _maybe_group(_round_dec(n, digits === nothing ? 2 : digits), sep) :
        kind === :scientific  ? _sci(n, digits === nothing ? 3 : digits) :
        kind === :bytes       ? _bytes(n, digits === nothing ? 1 : digits) :
        _maybe_group(_round_dec(n, digits === nothing ? 2 : digits), sep)   # :fixed (+ fallback)
    neg = startswith(body, "-")                    # sign sits OUTSIDE the prefix: -$1,234.50
    core = neg ? SubString(body, 2) : body
    return string(neg ? "-" : "", prefix, core, suffix)
end
