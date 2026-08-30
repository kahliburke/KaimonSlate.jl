try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 📦 Working with data too big to move

A sweep's ordinary result comes back whole. That is right up to a point, and hopeless past it —
a run whose units each write gigabytes has an aggregate nobody wants in a notebook process,
over a link nobody wants to saturate.

Adding `data=lazy` to a sweep cell changes where the result lives, not what the author writes.
The unit returns an ordinary array or table; Slate stores it in a layout whose pieces are
separately addressable and sends the notebook an **index** — schema, row counts, byte offsets,
per-chunk value ranges. Kilobytes, whatever the data weighs.

Reads then name a slice, the index turns it into a few byte ranges, and only those bytes move.
"""

#%% code id=target
# Where the work runs is defined ONCE for the notebook (the ⎈ on a sweep cell) and referenced by
# name from a cell header — `#%% sweep cluster=here`. Nothing below restates it, which is what lets
# the same cells run against a scheduler by editing one definition.
#
# Arrow is in this notebook's environment but is never imported by hand, here or in a unit: the
# storage layer loads it where it needs it. It is an implementation detail of `data=lazy`.
here = Sweep._ctx_clusters()["here"]

slate_table((; setting = collect(keys(here)), value = collect(values(here))))

#%% md id=h_write
@md"""
## The author writes ordinary Julia

The body below returns a `NamedTuple` of vectors — a table, written the way anyone would write it.
There is no Arrow call, no chunking, no index, no streaming API. The only thing that says this is a
large-output sweep is `data=lazy` on the cell header, beside `chunk=` and `cluster=`.

Each unit here makes 200k rows. At this scale the whole thing would fit in memory comfortably; the
point is that the *mechanism* does not care, because nothing about a read below is proportional to
the total.
"""

#%% sweep id=events cluster=here data=lazy
NRUN = 8          # units — think "one per detector run"
NROW = 200_000    # rows each

events = @sweep(paramgrid(run = 1:NRUN); summary = v -> length(v.energy)) do p
    using Random
    rng = Random.MersenneTwister(p.run)
    # Energy climbs with the run index, so a range predicate can genuinely skip whole units later.
    (; run    = fill(p.run, NROW),
       t      = cumsum(rand(rng, NROW)) ./ 1000,
       energy = p.run .+ randn(rng, NROW),
       ok     = rand(rng, NROW) .> 0.01)
end

#%% md id=h_read
@md"""
## What crossed the wire: an index

The sweep's value is a `Dataset` spanning every unit. Asking it what it *is* reads no data at all —
the schema, the row count and the size all come from the per-unit indices, which are kilobytes.

That is the property that has to hold at terabyte scale, and the reason the cells below can be
written at all: none of them is proportional to the total.
"""

#%% code id=describe
data = events.dataset

#%% md id=h_slice
@md"""
## Taking a slice

Rows are one space across every unit, so a range spanning a unit boundary is just a range. The
index says which chunks it falls in; only those are opened. Naming columns narrows it further —
the untouched ones are never faulted in.
"""

#%% code id=slice
# A window straddling the boundary between two units — `run` changes mid-slice, and nothing here
# had to know that the two halves came out of different jobs.
edge = data[599_995:600_004, (:run, :energy)]

slate_table((; row = 599_995:600_004, run = edge.run, energy = round.(edge.energy; digits = 3)))

#%% md id=h_scan
@md"""
## Filtering without reading

`scan` streams the dataset and keeps what matches. Two different things happen to the two kinds
of filter you can give it:

- `between = (:col, lo, hi)` is **pushed down to the index**. Each chunk recorded the range of
  values it holds, so a chunk that cannot contain a match is never opened.
- `where` is an ordinary Julia predicate. It cannot be pushed down, so it costs a read of the
  chunks that reach it — but `limit` still stops the whole thing early.

The counter below reports how much of the dataset each query actually had to open.
"""

#%% code id=prune
# What a query WOULD read, before it reads anything. `query_cost` answers from the index — the same
# numbers, and the same question, the reader asks before opening a chunk.
cost(q...) = Sweep.query_cost(data; between = isempty(q) ? nothing : q[1])

slate_table((;
    query  = ["everything", "energy 7.5 … 9", "energy 0 … 9", "run 1 … 1"],
    chunks = [string(cost().chunks, " / ", cost().of_chunks),
              string(cost((:energy, 7.5, 9)).chunks, " / ", cost().of_chunks),
              string(cost((:energy, 0, 9)).chunks, " / ", cost().of_chunks),
              string(cost((:run, 1, 1)).chunks, " / ", cost().of_chunks)],
    would_read = [cost().pretty, cost((:energy, 7.5, 9)).pretty,
                  cost((:energy, 0, 9)).pretty, cost((:run, 1, 1)).pretty],
    percent = [cost().percent, cost((:energy, 7.5, 9)).percent,
               cost((:energy, 0, 9)).percent, cost((:run, 1, 1)).percent]))

#%% md id=h_guard
@md"""
## No accidental terabyte

The reads above are small because they were written small. That is not enough: the API also has to
make the expensive thing hard to write by accident. A slice is capped, and going past the cap is a
different call that takes the number as an argument — so the size of a read is always visible at
the place it is requested.
"""

#%% code id=guard
# "Just give me the table" — the thing that must not silently work on a dataset this size.
refusal = try
    data[1:length(data)]
    "it went through (it should not have)"
catch e
    sprint(showerror, e)
end

println("asking for all ", length(data), " rows:\n\n", refusal,
        "\n\nthe escape hatch, with the number written down at the call site:\n",
        "  Sweep.load(data, 1:length(data); max_rows = ", length(data), ")")

#%% md id=h_array
@md"""
## The other shape: arrays

A unit that returns an `Array` of bits takes a different layout — a fixed header and the elements in
memory order. That needs no packages at all on the compute node, and it is the strongest case for
addressability: any sub-range is arithmetic, so a slice is one exact read with no index beyond the
dimensions.

Arrays stay separate parts rather than concatenating, because output of differing shape has no
single meaning stacked.
"""

#%% sweep id=field cluster=here data=lazy
NPIX = 256   # each unit computes one NPIX × NPIX plane

field = @sweep(paramgrid(slice = 1:6); summary = v -> sum(abs2, v)) do p
    z = (p.slice - 3.5) / 2
    [Float32(exp(-(x^2 + y^2 + z^2) / 40) * cos(x / 3) * sin(y / 4))
     for x in range(-12, 12; length = NPIX), y in range(-12, 12; length = NPIX)]
end

#%% code id=field_slice
planes = field.dataset

# One part, one narrow window inside it. The mapping starts at the range's first byte, so nothing
# before or after it is touched — 40 elements read out of a plane of 65,536.
window = planes[2][30_000:30_039]

println("part 2, elements 30,000–30,039 → ", length(window), " Float32 = ",
        Sweep._bytes(length(window) * 4), " read, out of ",
        Sweep._bytes(Sweep.databytes(planes)), " stored")
println("this session, every read so far: ", Sweep.transfers().pretty)

planes

#%% md id=h_xfer
@md"""
## Watching the transfer

Everything above is a claim about how little moved. This is the measurement — and it belongs to the
system, not to this notebook. Every read that moves bytes is recorded, and a **cluster** can be
asked what is going on with it: the sweeps in its store and how far along they are, what the
scheduler says is live, how much output is sitting there, and how much of it has come back.

The same figures ride the sweep card, so a run is watchable without writing any of this out.
"""

#%% code id=cluster_view
# `edge` and `window` name the reads above, so this cell runs after them — two cells with no data
# dependency between them have no order in a reactive notebook, and this one is about their effect.
edge, window

Sweep.cluster_status("here")

#%% code id=xfer
# Each read this session made. A query that costs more than it should shows up here as one oversized
# row, rather than as a slow drift in a total nobody is watching.
x = Sweep.transfers()

slate_table((; kind   = [string(r.kind) for r in x.recent],
               read   = [r.bytes for r in x.recent],
               chunks = [r.chunks for r in x.recent],
               ms     = [r.ms for r in x.recent],
               sweep  = [first(r.label, 18) for r in x.recent]))

# ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
#   Arrow 2.8.1 69666777-d1a9-59fb-9406-91d4454c9d45
# ╚═╡
# ╔═╡ Slate.clusters · compute targets (⎈ on a sweep cell)
#   [here]
#   kind = local
#   root = /Users/kburke/.cache/kaimonslate/dataset-demo
#   project = /Users/kburke/.julia/environments/kaimonslate/dataset_demo-40530ce3
#   payload = /Users/kburke/devel/KaimonSlate.jl/.claude/worktrees/feat+batch-fabric/src/slatetask.jl
#   chunk = 4
#   note = local processes - the same cells run against a scheduler unchanged
# ╚═╡
# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 3b9f8418-faec-4ca6-9e4c-167ba1bf4c12
# ╚═╡
