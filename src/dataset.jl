# ── Datasets: results too large to move ──────────────────────────────────────────────────────
#
# A sweep's ordinary data channel brings a unit's return value back to the notebook. That is the
# right default up to a point, and hopeless past it: a run whose units each write gigabytes has an
# aggregate nobody wants in a notebook process, over a link nobody wants to saturate.
#
# A DATASET inverts it. The unit's output is written where it ran, in a layout whose pieces are
# separately addressable, and what crosses to the notebook is an INDEX — schema, row counts, byte
# offsets, per-chunk value ranges. Kilobytes, whatever the dataset weighs. Reads then name a slice,
# the index turns it into a few byte ranges, and only those bytes move.
#
# The author writes none of this. They return a table or an array from the sweep body exactly as
# they would otherwise; the cell's `data=lazy` attribute is what decides that the result is stored
# addressably instead of whole. Format follows from the value:
#
#   array   an isbits `Array` — the `raw` codec's 64-byte header plus the elements. A slice is
#           arithmetic (`offset = 64 + i * sizeof(T)`), so ANY sub-range is one exact read with no
#           index beyond the dims. This is the strongest case and needs no packages at all.
#   table   anything column-shaped — written as a sequence of Arrow IPC chunks of a target byte
#           size, each its own CAS blob. A row range touches only the chunks covering it; a column
#           projection touches only that column's pages inside them. Per-chunk min/max lets a
#           predicate skip chunks outright.
#
# Chunking is what keeps the index small. One blob per ~64 MB means a terabyte is a few thousand
# entries spread across the units that wrote them — each unit's manifest carries only its own.

# Target bytes per table chunk. Big enough that per-chunk overhead is noise, small enough that
# reading one to answer a narrow slice is not itself a bulk transfer.
const DATASET_CHUNK_BYTES = 64 * 1024 * 1024
# …but a unit smaller than one chunk would BE a single chunk, and a single chunk cannot be pruned:
# every predicate would read all of it and so would every row range. Split into at least this many
# pieces so granularity does not vanish at the small end. It also bounds the other direction on its
# own — when the byte target is not binding this is exactly the chunk count, so a small unit can
# never shatter into hundreds of near-empty blobs.
const DATASET_MIN_CHUNKS = 8

# ── Shape detection ──────────────────────────────────────────────────────────────────────────
# Deliberately structural, not nominal: a sweep body returns whatever is natural for the science,
# and `using Tables` in the task environment is not something the author should have to arrange.
# Three column-shaped things cover essentially everything: a DataFrame, a NamedTuple of vectors,
# and a vector of NamedTuples (the shape a loop that pushes rows produces).

_ds_arrayable(v) = v isa Array && isbitstype(eltype(v)) && !isempty(v)

# A package the UNIT loaded is newer than this function. `_codec_loaded` finds DataFrames because a
# sweep body did `using DataFrames`, but that happened after this code was compiled, so its methods
# are not visible from this call site's world age and calling one directly raises "the applicable
# method may be too new". Every call into a soft-detected package has to go through `invokelatest`.
# The type is fetched the same way: a binding resolved in the old world is the same trap.
_late(D::Module, name::Symbol) = Base.invokelatest(getglobal, D, name)
_latecall(D::Module, name::Symbol, args...) = Base.invokelatest(_late(D, name), args...)

function _ds_columns(v)
    D = _codec_loaded("DataFrames")
    if D !== nothing && v isa _late(D, :DataFrame)
        return (String[String(n) for n in _latecall(D, :names, v)],
                Any[c for c in _latecall(D, :eachcol, v)])
    end
    if v isa NamedTuple && !isempty(v) && all(c -> c isa AbstractVector, values(v))
        n = length(first(values(v)))
        all(c -> length(c) == n, values(v)) || return nothing
        return (String[String(k) for k in keys(v)], Any[c for c in values(v)])
    end
    if v isa AbstractVector && !isempty(v) && all(r -> r isa NamedTuple, v)
        ks = keys(first(v))
        all(r -> keys(r) === ks, v) || return nothing
        return (String[String(k) for k in ks], Any[[r[k] for r in v] for k in ks])
    end
    return nothing
end

# Arrow, loading it if this process has not yet. Everywhere else in the codebase Arrow is SOFT
# detected — a value that happens to be a DataFrame gets a faster codec if the package is around.
# Here the situation is different: `data=lazy` is an explicit request for addressable storage, and a
# unit process has no reason to have imported Arrow on its own. Detecting its absence and silently
# storing whole would answer that request with the one thing it ruled out.
const _ARROW_TRIED = Ref(false)
const _ARROW_UUID = "69666777-d1a9-59fb-9406-91d4454c9d45"
function _ds_arrow()
    A = _codec_loaded("Arrow")
    A === nothing || return A
    _ARROW_TRIED[] && return nothing        # attempt the import once per process, not per unit
    _ARROW_TRIED[] = true
    try
        @eval Main using Arrow
        return _codec_loaded("Arrow")
    catch
    end
    # `using` only reaches a project's DIRECT dependencies, and Arrow is rarely one: a task
    # environment is provisioned from the user's science package, which may well depend on Arrow
    # without the environment naming it. Loading by UUID reaches anything the manifest resolves,
    # which is the honest test of "is it available here?".
    try
        return Base.require(Base.PkgId(Base.UUID(_ARROW_UUID), "Arrow"))
    catch
        return nothing
    end
end

# Importing a package at RUNTIME puts its methods in a newer world than the function that asked for
# it, so calling them directly fails with "method too new to be called from this world context"
# rather than dispatching. Every call into a module `_ds_arrow` may have just loaded goes through
# here. (Cheap: one dynamic dispatch per CHUNK, not per row.)
_arrow_call(f, args...; kw...) = Base.invokelatest(f, args...; kw...)

"Can `v` be stored addressably? `:array`, `:table`, or `nothing` (store it whole instead)."
function dataset_kind(v)
    _ds_arrayable(v) && return :array
    # Arrow is what makes a table addressable. If it cannot be loaded at all there is nothing to be
    # gained by pretending, and the ordinary codec path still stores a correct (if whole) result —
    # which the notebook reports rather than passing off as a complete dataset.
    _ds_columns(v) !== nothing && _ds_arrow() !== nothing && return :table
    return nothing
end

# ── Writing ──────────────────────────────────────────────────────────────────────────────────

# Bytes one row occupies, for chunk sizing. Fixed-width element types are exact; anything else
# (strings, most obviously) is sampled, because the alternative is measuring the whole column.
function _ds_row_bytes(cols)
    total = 0
    for c in cols
        T = eltype(c)
        if isbitstype(T)
            total += sizeof(T)
        else
            n = min(length(c), 64)
            s = 0
            for i in 1:n
                x = c[i]
                s += x isa AbstractString ? ncodeunits(x) + 4 : 16
            end
            total += max(1, cld(s, n))
        end
    end
    return max(1, total)
end

# Per-chunk value range for a numeric column: what lets `scan(...; where = …)` skip a chunk
# without reading it. Only cheap, order-comparable columns get one; anything else simply has no
# statistic and is never skipped on.
function _ds_chunk_stats(names, cols, lo, hi)
    st = Dict{String,Any}()
    for (nm, c) in zip(names, cols)
        eltype(c) <: Union{Real,Missing} || continue
        mn = nothing; mx = nothing
        for i in lo:hi
            x = c[i]
            (x === missing || x !== x) && continue     # skip missing and NaN
            mn = (mn === nothing || x < mn) ? x : mn
            mx = (mx === nothing || x > mx) ? x : mx
        end
        mn === nothing && continue
        st[nm] = Dict{String,Any}("min" => Float64(mn), "max" => Float64(mx))
    end
    return st
end

"""
    write_dataset!(root, value; chunk_bytes = DATASET_CHUNK_BYTES) -> (index, bytes) | nothing

Store `value` addressably in the CAS at `root` and return the index describing it, or `nothing` if
this value has no addressable form (the caller then stores it whole, as before).
"""
function write_dataset!(root::AbstractString, value; chunk_bytes::Integer = DATASET_CHUNK_BYTES)
    kind = dataset_kind(value)
    kind === nothing && return nothing

    if kind === :array
        # The `raw` codec is already an addressable layout: a fixed 64-byte header, then the
        # elements in memory order. Nothing to chunk — every sub-range is computable.
        h, n = MemoStore.put_blob(io -> _codec_encode(io, "raw", value), root)
        idx = Dict{String,Any}(
            "kind" => "array", "codec" => "raw", "blob" => h, "bytes" => Int(n),
            "offset" => 64, "dims" => collect(Int, size(value)),
            "eltype" => string(eltype(value)), "elsize" => sizeof(eltype(value)),
            "rows" => length(value))
        return (idx, Int(n))
    end

    A = _ds_arrow()
    names, cols = _ds_columns(value)
    nrows = isempty(cols) ? 0 : length(first(cols))
    rb = _ds_row_bytes(cols)
    # Whichever gives more pieces: the byte target, or splitting this unit into `DATASET_MIN_CHUNKS`.
    # A big unit chunks by size; a small one still ends up prunable.
    target = min(Int(chunk_bytes), max(1, cld(nrows * rb, DATASET_MIN_CHUNKS)))
    per = max(1, fld(target, rb))
    chunks = Dict{String,Any}[]
    total = 0
    lo = 1
    while lo <= nrows
        hi = min(nrows, lo + per - 1)
        part = NamedTuple{Tuple(Symbol.(names))}(Tuple(c[lo:hi] for c in cols))
        h, n = MemoStore.put_blob(io -> _arrow_call(A.write, io, part), root)
        push!(chunks, Dict{String,Any}(
            "blob" => h, "bytes" => Int(n), "rows" => hi - lo + 1,
            "stats" => _ds_chunk_stats(names, cols, lo, hi)))
        total += n
        lo = hi + 1
    end
    idx = Dict{String,Any}(
        "kind" => "table", "codec" => "arrow", "bytes" => total, "rows" => nrows,
        "columns" => names, "types" => String[string(eltype(c)) for c in cols],
        "chunks" => chunks)
    return (idx, total)
end

# ── Resolving a slice to byte ranges ─────────────────────────────────────────────────────────
# Pure index arithmetic — no I/O, so it is unit-testable without a store and cheap enough to run
# per request. The caller feeds the ranges to whichever reader applies (a local mmap, or the blob
# channel's ranged pull when the store is not on a visible mount).

"""
    array_range(index, i) -> (blob, offset, nbytes, count)

The exact bytes backing the LINEAR element range `i` of an array dataset.
"""
function array_range(index::AbstractDict, i::AbstractUnitRange)
    es = Int(index["elsize"])
    off = Int(index["offset"])
    n = Int(index["rows"])
    (first(i) >= 1 && last(i) <= n) ||
        throw(BoundsError("dataset element range $(i) outside 1:$(n)"))
    return (String(index["blob"]), off + (first(i) - 1) * es, length(i) * es, length(i))
end

"""
    table_chunks(index, rows) -> Vector{(pos, blob, lo, hi)}

Which stored chunks cover the row range `rows`, and which of THEIR rows are wanted. `pos` is the
chunk's index in the dataset, `lo:hi` its local row span.
"""
function table_chunks(index::AbstractDict, rows::AbstractUnitRange)
    out = Tuple{Int,String,Int,Int}[]
    at = 1
    for (pos, c) in enumerate(index["chunks"])
        n = Int(c["rows"])
        stop = at + n - 1
        if !(stop < first(rows) || at > last(rows))
            push!(out, (pos, String(c["blob"]),
                        max(first(rows), at) - at + 1, min(last(rows), stop) - at + 1))
        end
        at = stop + 1
        at > last(rows) && break
    end
    return out
end

"""
    prune_chunks(index, column, lo, hi) -> Vector{Int}

Chunk positions whose recorded range for `column` overlaps `[lo, hi]` — the ones a predicate on
that column could still match. A chunk with no statistic is always kept: an absent bound is not
evidence of absence.
"""
function prune_chunks(index::AbstractDict, column::AbstractString, lo::Real, hi::Real)
    keep = Int[]
    for (pos, c) in enumerate(index["chunks"])
        st = get(c, "stats", nothing)
        s = st === nothing ? nothing : get(st, String(column), nothing)
        if s === nothing || !(Float64(s["max"]) < lo || Float64(s["min"]) > hi)
            push!(keep, pos)
        end
    end
    return keep
end
