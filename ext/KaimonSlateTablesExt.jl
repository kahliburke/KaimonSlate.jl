### Tables.jl support for a sweep's `Dataset`, loaded only when the reader has Tables.
#
# A weak dependency rather than a hard one: Tables is worth nothing to someone who opens a notebook
# to plot a function, and it is already present for anyone who could use this — DataFrames, Arrow,
# CSV and DuckDB all depend on it. So the integration appears exactly when it is usable and costs
# nothing otherwise.
#
# Two surfaces, for the two things a consumer might mean.
#
# PARTITIONS is the one to reach for: a table per stored chunk, so `Arrow.write` and `CSV.write`
# stream a dataset larger than memory with one chunk resident at a time.
#
# COLUMNS materialises the lot, which is what `DataFrame(ds)` asks for and is exactly right on the
# pilot-sized sweeps that make up most of them. It goes through `load`, so the read guard applies:
# a dataset too big to want in memory refuses and says how to insist (`r.read_limit`,
# `Sweep.read_limit!`, or `max_bytes` on the call). The guard is priced off the index, so the
# refusal costs nothing and arrives before any bytes move.
module KaimonSlateTablesExt

import Tables
import KaimonSlate

const Sweep = KaimonSlate.ReportEngine.Sweep

Tables.istable(::Type{<:Sweep.Dataset}) = true

# One table per stored chunk, in row order. `Arrow.write` / `CSV.write` walk this and write each
# piece as it arrives, so peak residency is one chunk whatever the dataset's size.
Tables.partitions(ds::Sweep.Dataset) = Sweep.partitions(ds)

# Every row, in memory — through `load`, so the read guard decides whether that is allowed.
Tables.columnaccess(::Type{<:Sweep.Dataset}) = true
Tables.columns(ds::Sweep.Dataset) = Sweep.load(ds, 1:length(ds))

# Answered from the index, so it costs nothing and is exact about `Union{Missing,T}` — a column is
# missing precisely where a part does not carry it, which the index records. `nothing` only for a
# shape with no row space at all, where the question does not apply.
function Tables.schema(ds::Sweep.Dataset)
    ds.kind === :table || return nothing
    names, types = Sweep.column_schema(ds)
    return Tables.Schema(Tuple(names), Tuple(types))
end

end
