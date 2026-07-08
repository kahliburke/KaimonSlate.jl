# Server-paged data tables — the lazy complement to the eager `slate_table`
# (tables.jl). Ported (minimally, dependency-free) from Tachikoma.jl's `Paged`
# module: a PROVIDER holds the data and the client fetches ONE page at a time, so
# arbitrarily large / SQL-backed tables never ship whole.
#
# Shared by the engine AND the worker (included before capture.jl, like tables.jl).
# A provider lives wherever cells eval — the worker for the gate kernel, the engine
# for the in-process kernel — and is kept in a per-process registry keyed by a
# short id. The browser carries that id and POSTs page requests to /api/<id>/
# table-page, which routes back to `fetch_page` on the right provider.
#
# SQL is a SOFT dependency (DBInterface + Tables.jl detected via loaded_modules),
# so DuckDB/SQLite in the worker's project Just Works without KaimonSlate gaining a
# DB dependency.

# ── Protocol ──────────────────────────────────────────────────────────────────

# Paged tables use the same `ColumnDef` as eager tables (defined in tables.jl, included first), so
# every consumer reads ONE column shape. A numeric column (`type ∈ (:int,:float)`) sorts numerically.

"A request for one page: 1-based `page`, `sort_col` (0 = none), direction, global search."
struct PageRequest
    page::Int
    page_size::Int
    sort_col::Int         # 1-based; 0 = unsorted
    sort_desc::Bool
    search::String
end

"One page of rows plus the total row count of the (filtered) result."
struct PageResult
    rows::Vector{Vector{Any}}    # raw values (JSON-reduced at the emit boundary)
    total::Int
end

"A data source that serves pages on demand. Implement [`page_columns`](@ref) + [`fetch_page`](@ref)."
abstract type PagedProvider end

"`page_columns(provider) -> Vector{ColumnDef}` — the provider's columns."
function page_columns end
"`fetch_page(provider, ::PageRequest) -> PageResult` — one page, sorted/filtered/paged."
function fetch_page end

# Order-independent comparison tolerant of the mixed cell types a column can hold
# (numbers sort numerically; everything else by string; `nothing` sorts first).
function _pcmp(a, b)
    a === nothing && return b === nothing ? 0 : -1
    b === nothing && return 1
    if a isa Real && b isa Real
        return a < b ? -1 : (a > b ? 1 : 0)
    end
    sa, sb = string(a), string(b)
    return sa < sb ? -1 : (sa > sb ? 1 : 0)
end

# ── Per-process provider registry (bounded; oldest evicted) ──────────────────
const _PROVIDERS = Dict{String,Any}()
const _PROVIDER_ORDER = String[]
const _PROVIDER_SEQ = Ref(0)
const _MAX_PROVIDERS = 200

function _register_provider!(p)
    _PROVIDER_SEQ[] += 1
    id = "pt" * string(_PROVIDER_SEQ[]; base = 16)
    _PROVIDERS[id] = p
    push!(_PROVIDER_ORDER, id)
    while length(_PROVIDER_ORDER) > _MAX_PROVIDERS
        delete!(_PROVIDERS, popfirst!(_PROVIDER_ORDER))
    end
    return id
end

# Build a PageRequest from the frontend's JSON body (string keys, loose types).
function _page_request(d::AbstractDict)
    return PageRequest(
        max(1, Int(get(d, "page", 1))),
        clamp(Int(get(d, "page_size", 50)), 1, 1000),
        Int(get(d, "sort_col", 0)),
        get(d, "sort_desc", false) === true,
        String(get(d, "search", "")),
    )
end

# Look up a provider by id and return one page as a JSON-safe wire NamedTuple.
# (`_cellval` lives in tables.jl, included first.) Returns an empty page if the id
# is unknown (e.g. evicted, or a stale id from a since-recomputed cell).
function _provider_page(id::AbstractString, req::PageRequest)
    p = get(_PROVIDERS, String(id), nothing)
    p === nothing && return (rows = Vector{Any}[], total = 0)
    res = try
        fetch_page(p, req)
    catch
        return (rows = Vector{Any}[], total = 0)
    end
    rows = Vector{Any}[Any[_cellval(v) for v in r] for r in res.rows]
    return (rows = rows, total = res.total)
end

# ── SlatePagedTable marker + capture hooks ───────────────────────────────────

"A captured paged table: the registered provider id, columns, total, and page 1."
struct SlatePagedTable
    id::String
    columns::Vector{ColumnDef}
    total::Int
    page_size::Int
    page1::Vector{Vector{Any}}    # already JSON-safe
end

# Register `provider`, fetch page 1, and wrap it as a capturable marker.
function _make_paged(provider; page_size::Int = 50)
    cols = page_columns(provider)
    id = _register_provider!(provider)
    res = fetch_page(provider, PageRequest(1, page_size, 0, false, ""))
    rows = Vector{Any}[Any[_cellval(v) for v in r] for r in res.rows]
    return SlatePagedTable(id, cols, res.total, page_size, rows)
end

# A returned SlatePagedTable is captured as-is (more specific than tables.jl's
# generic `_as_slate_table`, so it wins dispatch).
_as_slate_table(t::SlatePagedTable) = t

_table_wire(t::SlatePagedTable) = Dict{String,Any}(
    "paged"    => true,
    "tableId"  => t.id,
    "columns"  => Any[_col_wire(c) for c in t.columns],   # shared column shape (tables.jl)
    "rows"     => t.page1,
    "pageSize" => t.page_size,
    "opts"     => Dict{String,Any}("nrows" => t.total, "ncols" => length(t.columns)),
)

function _paged_columns_data(x)
    T = _tables_mod()
    if T !== nothing
        ok = try Base.invokelatest(T.istable, x) === true catch; false end
        if ok
            cols = Base.invokelatest(T.columns, x)
            nm = Base.invokelatest(T.columnnames, cols)
            names = String[string(n) for n in nm]
            data = Vector{Any}[Any[v for v in Base.invokelatest(T.getcolumn, cols, n)] for n in nm]
            return (names, data)
        end
    end
    if x isa AbstractVector && !isempty(x) && all(r -> r isa NamedTuple, x)
        names = String[string(k) for k in keys(first(x))]
        syms = Symbol.(names)
        data = Vector{Any}[Any[get(r, s, nothing) for r in x] for s in syms]
        return (names, data)
    elseif x isa NamedTuple && !isempty(x) && all(v -> v isa AbstractVector, values(x))
        return (String[string(k) for k in keys(x)], Vector{Any}[Any[v for v in c] for c in values(x)])
    elseif x isa AbstractDict && !isempty(x) && all(v -> v isa AbstractVector, values(x))
        ks = collect(keys(x))
        return (String[string(k) for k in ks], Vector{Any}[Any[v for v in x[k]] for k in ks])
    end
    return nothing
end

# ── InMemoryPagedProvider ─────────────────────────────────────────────────────
"Pages/sorts/filters a column-major dataset in-process (the paged form of `slate_table`)."
struct InMemoryPagedProvider <: PagedProvider
    columns::Vector{ColumnDef}
    data::Vector{Vector{Any}}        # column-major
end

page_columns(p::InMemoryPagedProvider) = p.columns

function fetch_page(p::InMemoryPagedProvider, req::PageRequest)
    ncols = length(p.data)
    nrows = ncols == 0 ? 0 : length(p.data[1])
    idx = collect(1:nrows)
    if !isempty(req.search)
        q = lowercase(req.search)
        idx = filter(ri -> any(ci -> occursin(q, lowercase(string(p.data[ci][ri]))), 1:ncols), idx)
    end
    total = length(idx)
    if req.sort_col > 0 && req.sort_col <= ncols
        col = p.data[req.sort_col]
        sort!(idx; lt = (i, j) -> _pcmp(col[i], col[j]) < 0, rev = req.sort_desc)
    end
    start = (req.page - 1) * req.page_size + 1
    stop = min(start + req.page_size - 1, total)
    pidx = start <= total ? idx[start:stop] : Int[]
    rows = Vector{Any}[Any[p.data[ci][ri] for ci in 1:ncols] for ri in pidx]
    return PageResult(rows, total)
end

function _inmemory_provider(x)
    cd = _paged_columns_data(x)
    cd === nothing && return nothing
    names, data = cd
    return InMemoryPagedProvider(_infer_columns(names, data), data)   # `_infer_columns` from tables.jl
end

# ── SqlPagedProvider (soft DBInterface + Tables.jl; SQL pushdown) ────────────
_dbinterface_mod() = (for (id, m) in Base.loaded_modules; id.name == "DBInterface" && return m; end; nothing)

"Browses a SQL relation with sort/filter/paging pushed into the query (`slate_query`)."
struct SqlPagedProvider <: PagedProvider
    conn::Any
    sql::String                      # a SELECT; wrapped as a subquery
    columns::Vector{ColumnDef}
end

page_columns(p::SqlPagedProvider) = p.columns

# Escape a search term for a LIKE pattern (single-quote + LIKE metacharacters).
_like_arg(s) = "%" * lowercase(replace(string(s), "'" => "''", "\\" => "\\\\", "%" => "\\%", "_" => "\\_")) * "%"

# Quote a SQL identifier (column name) safely — double any internal `"`. Column names come from the
# query schema, but the user controls the SQL passed to `slate_query`, so an alias with a `"` would
# otherwise break out of the quoted identifier.
_sql_ident(name) = "\"" * replace(string(name), "\"" => "\"\"") * "\""

function _sql_where(p::SqlPagedProvider, req::PageRequest)
    isempty(req.search) && return ""
    arg = _like_arg(req.search)
    conds = ["LOWER(CAST($(_sql_ident(c.name)) AS VARCHAR)) LIKE '$arg' ESCAPE '\\'" for c in p.columns]
    return " WHERE (" * join(conds, " OR ") * ")"
end

function fetch_page(p::SqlPagedProvider, req::PageRequest)
    DB = _dbinterface_mod(); T = _tables_mod()
    (DB === nothing || T === nothing) && return PageResult(Vector{Any}[], 0)
    base = "FROM ($(p.sql)) AS _t" * _sql_where(p, req)
    cnt = Base.invokelatest(T.rowtable, Base.invokelatest(DB.execute, p.conn, "SELECT COUNT(*) AS n " * base))
    total = isempty(cnt) ? 0 : Int(cnt[1].n)
    order = ""
    if req.sort_col > 0 && req.sort_col <= length(p.columns)
        order = " ORDER BY $(_sql_ident(p.columns[req.sort_col].name)) " * (req.sort_desc ? "DESC" : "ASC")
    end
    off = (req.page - 1) * req.page_size
    cur = Base.invokelatest(DB.execute, p.conn,
                            "SELECT * " * base * order * " LIMIT $(req.page_size) OFFSET $off")
    rt = Base.invokelatest(T.rowtable, cur)
    nc = length(p.columns)
    rows = Vector{Any}[Any[r[i] for i in 1:nc] for r in rt]
    return PageResult(rows, total)
end

# Map a SQL schema column type to our physical column type (finer than the old :numeric/:text so the
# static exporters can align + format). `Missing` is stripped; date-like detected by type name.
function _sql_coltype(t)
    t === nothing && return :string
    nm = try Base.nonmissingtype(t) catch; t end
    nm isa Type || return :string
    nm <: Bool && return :bool
    nm <: Integer && return :int
    nm <: Real && return :float
    string(nameof(nm)) in ("Date", "DateTime", "Time") && return :date
    return :string
end

function _sql_provider(conn, sql::AbstractString)
    DB = _dbinterface_mod()
    DB === nothing && throw(ArgumentError("slate_query requires DBInterface.jl + a driver (DuckDB/SQLite) loaded"))
    T = _tables_mod()
    T === nothing && throw(ArgumentError("slate_query requires Tables.jl loaded"))
    probe = Base.invokelatest(DB.execute, conn, "SELECT * FROM ($sql) AS _t LIMIT 0")
    sch = Base.invokelatest(T.schema, probe)
    names = String[string(n) for n in sch.names]
    types = sch.types === nothing ? fill(:string, length(names)) : Symbol[_sql_coltype(t) for t in sch.types]
    cols = ColumnDef[ColumnDef(names[i], types[i], _default_align(types[i]), nothing, true, true) for i in eachindex(names)]
    return SqlPagedProvider(conn, String(sql), cols)
end

"""
    slate_query(conn, sql; page_size=50) -> SlatePagedTable

Browse the result of `sql` (run against DBInterface connection `conn`, e.g. a
`DuckDB.DB` or `SQLite.DB`) as a server-paged table: sorting, global search, and
paging are pushed into SQL, so the browser only ever holds one page. The whole
result set is never materialized.
"""
slate_query(conn, sql::AbstractString; page_size::Int = 50) =
    _make_paged(_sql_provider(conn, sql); page_size = page_size)
