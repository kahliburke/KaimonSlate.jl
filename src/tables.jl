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

"A captured tabular result: header names + JSON-safe row cells, rendered client-side."
struct SlateTable
    columns::Vector{String}
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

function _finish(names::Vector{String}, rows::Vector)
    total = length(rows)
    o = Dict{String,Any}("nrows" => total, "ncols" => length(names))
    if total > _MAX_TABLE_ROWS
        rows = rows[1:_MAX_TABLE_ROWS]
        o["truncated"] = true
    end
    return SlateTable(names, Vector{Vector{Any}}(rows), o)
end

function _from_columns(names::Vector{String}, cols)
    n = isempty(cols) ? 0 : maximum(length, cols)
    rows = Vector{Any}[Any[_cellval(i <= length(c) ? c[i] : nothing) for c in cols] for i in 1:n]
    return _finish(names, rows)
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
        rows = Vector{Any}[Any[_cellval(coldata[j][i]) for j in eachindex(coldata)] for i in 1:n]
        return _finish(snames, rows)
    catch
        return nothing
    end
end

# No-dependency shapes (used when Tables.jl isn't loaded, or for plain containers).
function _table_manual(x)
    if x isa AbstractVector
        isempty(x) && return SlateTable(String[], Vector{Any}[], Dict{String,Any}("nrows" => 0, "ncols" => 0))
        if all(r -> r isa NamedTuple, x)
            cols = String[string(k) for k in keys(first(x))]
            syms = Symbol.(cols)
            rows = Vector{Any}[Any[_cellval(get(r, s, nothing)) for s in syms] for r in x]
            return _finish(cols, rows)
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

# ── Public helper (injected into the cell namespace as `slate_table`) ─────────

"""
    slate_table(data) -> SlateTable
    slate_table(columns, rows) -> SlateTable

Build an interactive table. `data` may be a DataFrame / any Tables.jl source, a
`Vector` of `NamedTuple` rows, or a `Dict`/`NamedTuple` of equal-length column
vectors. The two-argument form takes explicit column names plus `rows` (a vector
of row vectors/tuples, or an `AbstractMatrix`). Cells are reduced to JSON-safe
scalars; numbers stay numeric so the browser sorts them numerically.
"""
slate_table(t::SlateTable) = t

# `paged=true` builds a server-paged table (provider lives where cells eval; the
# browser fetches one page at a time) — see paged.jl. Otherwise the eager form
# below materializes all rows (capped). `page_size` sets the paged page length.
function slate_table(x; paged::Bool = false, page_size::Int = 50)
    if paged
        prov = _inmemory_provider(x)
        prov === nothing && throw(ArgumentError(
            "slate_table(…; paged=true): cannot tabulate $(typeof(x)) — pass a DataFrame/Tables.jl " *
            "source, a Vector of NamedTuples, or a Dict/NamedTuple of column vectors."))
        return _make_paged(prov; page_size = page_size)
    end
    t = _as_slate_table(x)
    t === nothing || return t
    t = _table_manual(x)
    t === nothing || return t
    throw(ArgumentError(
        "slate_table: cannot tabulate $(typeof(x)) — pass a DataFrame/Tables.jl source, " *
        "a Vector of NamedTuples, a Dict/NamedTuple of column vectors, or `columns, rows`."))
end

function slate_table(columns, rows)
    names = String[string(c) for c in columns]
    rws = rows isa AbstractMatrix ?
        Vector{Any}[Any[_cellval(rows[i, j]) for j in 1:size(rows, 2)] for i in 1:size(rows, 1)] :
        Vector{Any}[Any[_cellval(v) for v in r] for r in rows]
    return _finish(names, rws)
end

# The wire representation carried in `run_capture`'s `tables` field (raw Dict;
# serializes over the gate and JSON-encodes server-side, like an echarts option).
_table_wire(t::SlateTable) = Dict{String,Any}("columns" => t.columns, "rows" => t.rows, "opts" => t.opts)
