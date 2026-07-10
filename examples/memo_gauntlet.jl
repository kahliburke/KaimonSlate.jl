#%% md id=title title
# Memo Gauntlet — restore fidelity across worker restarts

*A QA notebook for the durable memo store: `cache`-tagged cells carrying awkward values.
Run it, reap the worker, reopen — every restored binding must fingerprint identically to
the fresh run, and the two identical big vectors must dedup to one blob.*

#%% code id=deps
using DataFrames, Dates

#%% code id=mg_df cache
## A DataFrame with missing, unicode, and dates.
sleep(0.5)   # past nothing; the `cache` tag persists regardless
mg_df = DataFrame(name = ["αβ🚀", "plain", missing],
                  when = [Date(2026, 7, 9), Date(1987, 1, 1), Date(2000, 2, 29)],
                  x = [1.5, missing, -0.0])

#%% code id=mg_dict cache
## A Dict of awkward scalars: nothing, NaN, BigInt, Rational, Complex, Symbol keys.
mg_dict = Dict{Symbol,Any}(:none => nothing, :nan => NaN, :big => big(2)^200,
                           :rat => 22 // 7, :z => 3.0 + 4.0im, :sym => :marker)

#%% code id=mg_nothing cache
## A binding whose VALUE is nothing — the store's explicit found-flag path.
mg_maybe = nothing

#%% code id=mg_vec1 cache
## 1M floats with NaN/Inf sprinkled in.
mg_vec1 = let v = collect(range(0.0, 1.0; length = 1_000_000))
    v[1000] = NaN; v[2000] = Inf; v[3000] = -Inf
    v
end;
"vec1 ready"

#%% code id=mg_vec2 cache
## IDENTICAL content to mg_vec1, cached separately — must dedup to the SAME blob.
mg_vec2 = let v = collect(range(0.0, 1.0; length = 1_000_000))
    v[1000] = NaN; v[2000] = Inf; v[3000] = -Inf
    v
end;
"vec2 ready"

#%% code id=fingerprint nocache
## Canonical fingerprint over every cached binding — must be identical fresh vs restored.
"fingerprint: " * slate_fingerprint(mg_df, mg_dict, mg_maybe, mg_vec1, mg_vec2)

#%% md id=store_md
## What the store holds

One row per cached entry; `mg_vec1`/`mg_vec2` must show the **same blob hash** — 8 MB
stored once. `slate_memo_stats()` gives the store totals.

#%% code id=store_view nocache
s = slate_memo_stats()
slate_table(slate_memo_entries(); page_size = 10)

#%% code id=store_stats nocache
"store: $(s.manifests) entries · $(s.blobs) unique blobs · $(round(s.bytes / 1e6; digits = 1)) MB at $(s.root)"
