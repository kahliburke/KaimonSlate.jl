# Interactive data tables (interactivity Layer 2, sibling of echarts.jl). Shared by
# the engine AND the gate worker (both `include` it before `capture.jl`), so there
# is exactly one tabulation implementation — mirroring how `capture.jl` is shared.
#
# A cell returns `slate_table(data)` (explicit) OR simply returns a DataFrame / any
# Tables.jl source (auto-rendered). The value is captured as a `SlateTable` whose
# columns + rows are reduced to JSON-safe primitives HERE (in the eval frame, where
# the value is live), then carried raw in the wire form's `tables` field and
# JSON-encoded server-side — the same "encode server-side" path echarts uses. The
# browser hydrates it into a sortable / filterable / paginated table.
#
# Tables.jl is a SOFT dependency: detected via `Base.loaded_modules` (so DataFrames
# in the worker's project just works) and never added to KaimonSlate's deps. The
# no-dependency shapes (Vector of NamedTuples, Dict/NamedTuple of column vectors,
# explicit columns+rows / matrix) are handled directly with Base alone.

# Per-column display FORMAT (opt-in via the `slate_table(…; format=…)` DSL). Serializable data —
# NOT a closure — so it rides the wire and is applied identically by the Julia renderer
# (`_format_cell`, server-side exports) and the JS renderer (`fmtCell`, live table). `nothing`
# format ⇒ raw stringify (the historical behavior; output stays byte-identical unless opted in).
struct ColumnFormat
    kind::Symbol                  # :integer :fixed :currency :percent :scientific :bytes
    digits::Union{Int,Nothing}    # decimals / sig-figs; nothing ⇒ per-kind default
    sep::Bool                     # thousands grouping of the integer part
    prefix::String                # e.g. "$"
    suffix::String                # e.g. " kg"
end

# A table column: display NAME, PHYSICAL `type` (drives numeric sort + default alignment), `align`,
# an optional display `format`, and capability flags. `type` (physical) and `format.kind` (display)
# are orthogonal — a `:float` column may carry a `:currency` format. Shared by eager (`SlateTable`)
# and paged (`SlatePagedTable`, paged.jl) tables so all consumers read ONE column shape.
struct ColumnDef
    name::String
    type::Symbol                  # :int :float :bool :string :date   (numeric = :int | :float)
    align::Symbol                 # :left :right :center
    format::Union{ColumnFormat,Nothing}
    sortable::Bool
    filterable::Bool
    viz::Symbol                   # :none :bar :heat — in-cell visualization for a numeric column
    domain::Union{Nothing,Tuple{Float64,Float64}}   # (min,max) for scaling bar/heat; nothing = non-numeric / no data
end
# Back-compat convenience: the 6-arg form (pre-viz call sites) defaults viz/domain.
ColumnDef(name, type, align, format, sortable, filterable) =
    ColumnDef(name, type, align, format, sortable, filterable, :none, nothing)

# (min, max) of a column's finite numeric RAW values, or nothing (used to scale :bar/:heat).
function _col_domain(col)
    lo = Inf; hi = -Inf
    for v in col
        (v isa Real && !(v isa Bool) && isfinite(v)) || continue
        f = Float64(v); f < lo && (lo = f); f > hi && (hi = f)
    end
    return isfinite(lo) ? (lo, hi) : nothing
end

# Alignment implied by a column's physical type (numbers right, bools centered, else left).
_default_align(t::Symbol) = (t === :int || t === :float) ? :right : (t === :bool ? :center : :left)

# Physical type of a column, inferred from its RAW values (before `_cellval` reduction). Scans
# non-missing values; `Bool` is treated as its own type (not `:int`, though `Bool <: Integer`).
# Date-like values are detected by TYPE NAME to avoid a hard `Dates` dependency (tables.jl stays
# dependency-free). Empty / all-missing ⇒ `:string`.
_is_datelike(v) = nameof(typeof(v)) in (:Date, :DateTime, :Time)
function _infer_type(col)::Symbol
    seen = false; allbool = true; allint = true; allreal = true; alldate = true
    for v in col
        (v === nothing || v === missing) && continue
        seen = true
        b = v isa Bool
        allbool &= b
        allint  &= (v isa Integer && !b)
        allreal &= (v isa Real && !b)
        alldate &= _is_datelike(v)
    end
    seen || return :string
    allbool && return :bool
    allint  && return :int
    allreal && return :float
    alldate && return :date
    return :string
end

# Build default `ColumnDef`s (inferred type, default align, no format, sortable+filterable) from
# column NAMES + column-major RAW data. The `slate_table(…; format=/align=/coltype=)` DSL overlays
# onto these via `_apply_col_opts!`.
function _infer_columns(names::Vector{String}, rawcols)::Vector{ColumnDef}
    cols = Vector{ColumnDef}(undef, length(names))
    for i in eachindex(names)
        rc = i <= length(rawcols) ? rawcols[i] : ()
        t = _infer_type(rc)
        dom = (t === :int || t === :float) ? _col_domain(rc) : nothing   # for :bar/:heat scaling
        cols[i] = ColumnDef(names[i], t, _default_align(t), nothing, true, true, :none, dom)
    end
    return cols
end

"A captured tabular result: typed columns + JSON-safe row cells, rendered client-side."
struct SlateTable
    columns::Vector{ColumnDef}
    rows::Vector{Vector{Any}}     # each cell is a JSON-safe scalar (number/bool/string/nothing)
    opts::Dict{String,Any}        # nrows, ncols, truncated, … (surfaced to the UI)
end

# Don't ship an unbounded table over the wire / into the browser. Cap rows and flag
# truncation so the UI can say "showing N of M" — never a silent cap (§ no-silent-caps).
const _MAX_TABLE_ROWS = 5000

# ── Cell value → JSON-safe scalar ─────────────────────────────────────────────
# Numbers stay numbers (so the client can sort numerically); everything else becomes
# a display string. Non-finite floats and out-of-range integers stringify (JSON has
# no NaN/Inf, and JS numbers lose precision past 2^53), which keeps the whole
# `/state` payload valid JSON.
_safe_string(x) =
    try
        s = Base.invokelatest(sprint, show, MIME("text/plain"), x; context = :limit => true)
        length(s) > 200 ? first(s, 199) * "…" : s
    catch
        "?"
    end

function _cellval(x)
    (x === nothing || x === missing) && return nothing
    x isa Bool && return x
    if x isa Integer
        return (typemin(Int64) <= x <= typemax(Int64)) ? Int64(x) : string(x)
    end
    if x isa AbstractFloat
        return isfinite(x) ? Float64(x) : string(x)
    end
    if x isa Real
        f = try Float64(x) catch; nothing end
        return (f !== nothing && isfinite(f)) ? f : _safe_string(x)
    end
    x isa AbstractString && return String(x)
    x isa Symbol && return String(x)
    return _safe_string(x)
end

# ── Builders ──────────────────────────────────────────────────────────────────

function _finish(cols::Vector{ColumnDef}, rows::Vector)
    total = length(rows)
    o = Dict{String,Any}("nrows" => total, "ncols" => length(cols))
    if total > _MAX_TABLE_ROWS
        rows = rows[1:_MAX_TABLE_ROWS]
        o["truncated"] = true
    end
    return SlateTable(cols, Vector{Vector{Any}}(rows), o)
end

function _from_columns(names::Vector{String}, cols)
    n = isempty(cols) ? 0 : maximum(length, cols)
    rows = Vector{Any}[Any[_cellval(i <= length(c) ? c[i] : nothing) for c in cols] for i in 1:n]
    return _finish(_infer_columns(names, cols), rows)   # `cols` are RAW column vectors → infer types
end

# The loaded `Tables` module, or `nothing` — a soft dependency (no `import Tables`).
function _tables_mod()
    for (id, m) in Base.loaded_modules
        id.name == "Tables" && return m
    end
    return nothing
end

# Any Tables.jl source (DataFrame, Vector{<:NamedTuple}, …) → SlateTable, or nothing
# if Tables isn't loaded / `x` isn't a table / extraction fails (falls back to text).
function _table_from_tables(x)
    T = _tables_mod()
    T === nothing && return nothing
    try
        (Base.invokelatest(T.istable, x) === true) || return nothing
        cols = Base.invokelatest(T.columns, x)
        names = Base.invokelatest(T.columnnames, cols)
        snames = String[string(n) for n in names]
        coldata = Any[Base.invokelatest(T.getcolumn, cols, n) for n in names]
        n = isempty(coldata) ? 0 : maximum(length, coldata)
        # Bounds-safe like `_from_columns` below: a Tables.jl source isn't guaranteed to have
        # equal-length columns (DataFrames does, but the interface itself doesn't), so a ragged
        # column would otherwise throw a BoundsError here instead of degrading to a padded cell.
        rows = Vector{Any}[Any[_cellval(i <= length(coldata[j]) ? coldata[j][i] : nothing) for j in eachindex(coldata)] for i in 1:n]
        return _finish(_infer_columns(snames, coldata), rows)   # `coldata` are RAW columns
    catch
        return nothing
    end
end

# No-dependency shapes (used when Tables.jl isn't loaded, or for plain containers).
function _table_manual(x)
    if x isa AbstractVector
        isempty(x) && return SlateTable(ColumnDef[], Vector{Any}[], Dict{String,Any}("nrows" => 0, "ncols" => 0))
        if all(r -> r isa NamedTuple, x)
            names = String[string(k) for k in keys(first(x))]
            syms = Symbol.(names)
            rawcols = Any[Any[get(r, s, nothing) for r in x] for s in syms]   # column-major RAW → infer types
            rows = Vector{Any}[Any[_cellval(get(r, s, nothing)) for s in syms] for r in x]
            return _finish(_infer_columns(names, rawcols), rows)
        end
    elseif x isa NamedTuple && !isempty(x) && all(v -> v isa AbstractVector, values(x))
        return _from_columns(String[string(k) for k in keys(x)], collect(values(x)))
    elseif x isa AbstractDict && !isempty(x) && all(v -> v isa AbstractVector, values(x))
        ks = collect(keys(x))
        return _from_columns(String[string(k) for k in ks], Any[x[k] for k in ks])
    end
    return nothing
end

# What `capture.jl` calls on a returned value to decide auto-rendering: an explicit
# `SlateTable` or a Tables.jl source. Plain NamedTuple-vectors auto-render too when
# Tables.jl is loaded (DataFrames pulls it in); without it, wrap them in `slate_table`.
_as_slate_table(x) = x isa SlateTable ? x : _table_from_tables(x)

# ── Per-column format/align DSL (opt-in; columns auto-inferred when omitted) ──

# Default `ColumnFormat` for a preset kind — the params a bare `:preset` expands to before overrides.
function _format_preset(kind::Symbol)::ColumnFormat
    kind === :currency   ? ColumnFormat(:currency, 2, true, "\$", "") :
    kind === :percent    ? ColumnFormat(:percent, 1, false, "", "") :
    kind === :integer    ? ColumnFormat(:integer, nothing, true, "", "") :
    kind === :fixed      ? ColumnFormat(:fixed, 2, false, "", "") :
    kind === :scientific ? ColumnFormat(:scientific, 3, false, "", "") :
    kind === :bytes      ? ColumnFormat(:bytes, 1, false, "", "") :
    throw(ArgumentError("unknown format preset :$kind (expected one of :currency :percent :integer :fixed :scientific :bytes)"))
end

_fmt_get(d::NamedTuple, k, default) = haskey(d, k) ? getfield(d, k) : default
_fmt_get(d::AbstractDict, k, default) = haskey(d, k) ? d[k] : get(d, String(k), default)

# Parse one column's format spec: a preset `Symbol` (`:currency`), or a `NamedTuple`/`Dict` naming a
# `kind` plus overrides (`(kind=:currency, digits=0, prefix="€")`).
function _parse_col_format(spec)::ColumnFormat
    spec isa Symbol && return _format_preset(spec)
    if spec isa NamedTuple || spec isa AbstractDict
        kind = Symbol(_fmt_get(spec, :kind, :fixed))
        base = _format_preset(kind)
        return ColumnFormat(kind,
            _fmt_get(spec, :digits, base.digits),
            Bool(_fmt_get(spec, :sep, base.sep)),
            String(_fmt_get(spec, :prefix, base.prefix)),
            String(_fmt_get(spec, :suffix, base.suffix)))
    end
    throw(ArgumentError("format spec must be a preset Symbol (e.g. :currency) or a NamedTuple " *
                        "(e.g. (kind=:currency, digits=2)); got $(typeof(spec))"))
end

# Overlay user `format=`/`align=`/`coltype=` (each a column-name-keyed NamedTuple/Dict) onto the
# inferred `ColumnDef`s IN PLACE (immutable structs → replace by index). An unknown column name is a
# build-time authoring typo → hard error listing the available names.
function _apply_col_opts!(cols::Vector{ColumnDef}; format = NamedTuple(), align = NamedTuple(),
                         coltype = NamedTuple(), viz = NamedTuple())
    idx = Dict(c.name => i for (i, c) in enumerate(cols))
    _at(nm) = (i = get(idx, String(nm), nothing); i === nothing &&
        throw(ArgumentError("slate_table: no column \"$nm\" (have: $(join((c.name for c in cols), ", ")))")); i)
    for (nm, v) in pairs(coltype)
        i = _at(nm); c = cols[i]; t = Symbol(v)
        cols[i] = ColumnDef(c.name, t, _default_align(t), c.format, c.sortable, c.filterable, c.viz, c.domain)
    end
    for (nm, v) in pairs(align)
        i = _at(nm); c = cols[i]
        cols[i] = ColumnDef(c.name, c.type, Symbol(v), c.format, c.sortable, c.filterable, c.viz, c.domain)
    end
    for (nm, v) in pairs(format)
        i = _at(nm); c = cols[i]
        cols[i] = ColumnDef(c.name, c.type, c.align, _parse_col_format(v), c.sortable, c.filterable, c.viz, c.domain)
    end
    for (nm, v) in pairs(viz)
        i = _at(nm); c = cols[i]
        cols[i] = ColumnDef(c.name, c.type, c.align, c.format, c.sortable, c.filterable, Symbol(v), c.domain)
    end
    return cols
end

# ── Public helper (injected into the cell namespace as `slate_table`) ─────────

"""
    slate_table(data; format=…, align=…, coltype=…, viz=…) -> SlateTable
    slate_table(columns, rows; …) -> SlateTable

Build an interactive table. `data` may be a DataFrame / any Tables.jl source, a
`Vector` of `NamedTuple` rows, or a `Dict`/`NamedTuple` of equal-length column
vectors. The two-argument form takes explicit column names plus `rows` (a vector
of row vectors/tuples, or an `AbstractMatrix`). Cells are reduced to JSON-safe
scalars; numbers stay numeric so the browser sorts them numerically.

Each column's physical type (`:int`/`:float`/`:bool`/`:date`/`:string`) and default alignment are
inferred. Opt into display formatting per column via `format` (a NamedTuple/Dict keyed by column
name); a value is a preset `Symbol` or a `NamedTuple` naming a `kind` plus overrides. `align` and
`coltype` likewise override the inferred defaults:

    slate_table(df; format = (Revenue = :currency, Margin = (kind=:percent, digits=1)),
                    align  = (Product = :left,))

`viz` adds an in-cell visualization to a numeric column, scaled over its min→max: `:bar` (a
proportional bar behind the value) or `:heat` (a background shaded by magnitude):

    slate_table(df; format = (Revenue = :currency,), viz = (Revenue = :bar, Margin = :heat))

`export_rows = n` caps the rows shown in FIXED exports (PDF / markdown / static HTML) to the first
`n` (with a "showing n of N" note); the live table stays fully paginated.
"""

# `paged=true` builds a server-paged table (provider lives where cells eval; the
# browser fetches one page at a time) — see paged.jl. Otherwise the eager form
# below materializes all rows (capped). `page_size` sets the paged page length.
function slate_table(x; paged::Bool = false, page_size::Int = 50, export_rows = nothing,
                     format = NamedTuple(), align = NamedTuple(), coltype = NamedTuple(), viz = NamedTuple())
    if paged
        prov = _inmemory_provider(x)
        prov === nothing && throw(ArgumentError(
            "slate_table(…; paged=true): cannot tabulate $(typeof(x)) — pass a DataFrame/Tables.jl " *
            "source, a Vector of NamedTuples, or a Dict/NamedTuple of column vectors."))
        pt = _make_paged(prov; page_size = page_size)
        _apply_col_opts!(pt.columns; format, align, coltype, viz)
        return pt   # paged tables are already page-limited in fixed exports (only page 1 ships)
    end
    t = _as_slate_table(x)
    t === nothing && (t = _table_manual(x))
    t === nothing && throw(ArgumentError(
        "slate_table: cannot tabulate $(typeof(x)) — pass a DataFrame/Tables.jl source, " *
        "a Vector of NamedTuples, a Dict/NamedTuple of column vectors, or `columns, rows`."))
    _apply_col_opts!(t.columns; format, align, coltype, viz)
    export_rows === nothing || (t.opts["export_rows"] = Int(export_rows))   # cap rows in fixed exports (PDF/md/HTML)
    return t
end

function slate_table(columns, rows; export_rows = nothing,
                     format = NamedTuple(), align = NamedTuple(), coltype = NamedTuple(), viz = NamedTuple())
    names = String[string(c) for c in columns]
    ncol = length(names)
    rawrows = rows isa AbstractMatrix ?
        [Any[rows[i, j] for j in 1:size(rows, 2)] for i in 1:size(rows, 1)] :
        [collect(Any, r) for r in rows]
    rws = Vector{Any}[Any[_cellval(v) for v in r] for r in rawrows]
    rawcols = Any[Any[(j <= length(r) ? r[j] : nothing) for r in rawrows] for j in 1:ncol]
    cols = _infer_columns(names, rawcols)
    _apply_col_opts!(cols; format, align, coltype, viz)
    t = _finish(cols, rws)
    export_rows === nothing || (t.opts["export_rows"] = Int(export_rows))
    return t
end

# Serialize a column (+ its optional format) to the wire — the SINGLE column shape shared by eager
# and paged (`paged.jl`) tables, so every consumer reads one `{name,type,align,format,…}` object.
_format_wire(::Nothing) = nothing
_format_wire(f::ColumnFormat) = Dict{String,Any}(
    "kind" => String(f.kind), "digits" => f.digits, "sep" => f.sep, "prefix" => f.prefix, "suffix" => f.suffix)
function _col_wire(c::ColumnDef)
    d = Dict{String,Any}("name" => c.name, "type" => String(c.type), "align" => String(c.align),
        "format" => _format_wire(c.format), "sortable" => c.sortable, "filterable" => c.filterable)
    if c.viz !== :none                                   # in-cell bar/heat + its numeric domain (min,max)
        d["viz"] = String(c.viz)
        c.domain === nothing || (d["domain"] = Any[c.domain[1], c.domain[2]])
    end
    return d
end

# The wire representation carried in `run_capture`'s `tables` field (raw Dict;
# serializes over the gate and JSON-encodes server-side, like an echarts option).
_table_wire(t::SlateTable) = Dict{String,Any}(
    "columns" => Any[_col_wire(c) for c in t.columns], "rows" => t.rows, "opts" => t.opts)
