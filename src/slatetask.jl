# The batch-fabric task runner: the process a scheduler actually starts on a compute node.
#
# It is deliberately stateless. Given a CAS root and a chunk key it reads a descriptor, restores
# each shard's inputs from the store, runs the shard, and writes the result back as an ORDINARY
# memo entry. There is no gate, no ZMQ, no port, no tunnel, and no connection back to the hub: a
# task communicates only through the shared filesystem. That is what lets a sweep survive the hub
# being closed for a day.
#
# Shard results are written in the SAME manifest schema the worker's memoization uses, so they are
# not a parallel universe: `MemoStore.gc` refcounts their blobs, `pack`/`unpack` carry them into a
# standalone notebook, pins protect them, and `entry_bytes` prices them, all with no batch-specific
# code. Extra keys (status, ms, ran_on, artifacts) ride alongside and are ignored by readers that
# do not know about them.
#
# Idempotence is the whole design. A shard whose manifest already exists is skipped, so re-running
# a chunk is free, a requeued or preempted job resumes rather than repeats, and re-submitting a
# whole sweep costs nothing for the shards that already landed.

# `Base.include(@__MODULE__, …)` rather than a bare `include`: THIS call runs in whatever module is
# including this file, which may be a notebook's — and a module built programmatically has no
# `include` of its own.
#
# That is true here and only here. A `module … end` block always gets an `include` of its own, even
# inside a file loaded this way, so the includes within `module SlateTask` below are ordinary ones.
# They were `Base.include` too, which is invisible to Revise: it finds a package's files by walking
# recognisable `include("file.jl")` calls, so every file reached that way stopped hot-reloading and
# an edit to it needed a worker restart to take effect.
if !isdefined(@__MODULE__, :MemoStore)
    Base.include(@__MODULE__, joinpath(@__DIR__, "memostore.jl"))
end

module SlateTask

import Serialization
import TOML
import Dates
import Logging

const MemoStore = parentmodule(@__MODULE__).MemoStore

# The same value↔bytes codecs the memo layer uses. `raw` writes an isbits array as a
# self-describing header plus its bytes: the blob mmaps, so a slice reads only the pages it touches,
# and the header answers "what is in here?" without opening the data at all. Stdlib-only (`Mmap`;
# Arrow is soft-detected), so it loads in a runner that carries no dependencies.
include("memocodecs.jl")

# Storing a result ADDRESSABLY rather than whole — the layouts and the index that lets a notebook
# slice a dataset without moving it. Uses the codecs above, so it comes after them.
include("dataset.jl")

# Everything a task process needs beside it. Declared here, next to the includes it mirrors, so
# provisioning a cluster cannot silently ship a runner without one of its own parts.
const PAYLOAD_FILES = ("memostore.jl", "memocodecs.jl", "dataset.jl", "slatetask.jl")

const KIND_CHUNK = "slate-chunk"
const KIND_SHARD = "slate-shard"

# ── Artifacts ────────────────────────────────────────────────────────────────────────────────
# A shard may produce FILES as well as a return value: a solver's output, a NetCDF, a plot. Those
# go into the CAS like any other blob and are recorded on the shard's manifest, which is what keeps
# them alive through `gc` (see `_manifest_blobs`). The value comes back to the notebook eagerly;
# artifacts stay on the cluster as references until something asks for them.
const _ARTIFACTS = Ref{Union{Nothing,Vector{Dict{String,Any}}}}(nothing)
const _ROOT = Ref{String}("")

"""
    artifact!(path; name = basename(path)) -> String

Register a file this shard produced into the store, returning its content hash. Callable only from
inside a running shard.
"""
function artifact!(path::AbstractString; name::AbstractString = basename(path))
    acc = _ARTIFACTS[]
    acc === nothing && error("artifact!() called outside a running shard")
    isfile(path) || error("artifact!(): no such file: $path")
    h, n = MemoStore.put_blob(io -> open(p -> write(io, p), path, "r"), _ROOT[])
    push!(acc, Dict{String,Any}("name" => String(name), "blob" => h, "bytes" => n))
    return h
end

# ── Where a shard writes files ───────────────────────────────────────────────────────────────
# A notebook's `datadir()` is `<project>/data`, or whatever `KAIMONSLATE_DATADIR` pins for a region.
# A batch job has neither: no notebook project, no worker environment. So a shard gets the same two
# names resolving to the store's sibling `data` directory — on the cluster filesystem the store
# already lives on, and untouched by `gc`, which walks only `blobs/` and `manifests/`.
#
# A unit body written against `datadir()`/`@sfile` therefore runs unchanged whether it executes in
# the notebook, on a region worker, or as a batch shard. Without this a body that writes its own
# HDF5 or NetCDF file has nowhere portable to put it.
function shard_datadir(root::AbstractString)
    r = strip(get(ENV, "KAIMONSLATE_DATADIR", ""))
    d = isempty(r) ? joinpath(String(root), "data") : String(r)
    mkpath(d)
    return d
end

# `@sfile "a/b.nc"` → a path under `datadir()` whose parent exists, so it is usable as a write
# target immediately. Same contract as the notebook macro.
function shard_dpath(root::AbstractString, name::AbstractString)
    p = joinpath(shard_datadir(root), String(name))
    mkpath(dirname(p))
    return p
end

# ── Descriptor construction ──────────────────────────────────────────────────────────────────

_put_jls(root, v) = MemoStore.put_blob(io -> Serialization.serialize(io, v), root)
_put_txt(root, s) = MemoStore.put_blob(io -> write(io, s), root)

function _get_jls(root, h)
    found, v = MemoStore.with_blob(io -> Serialization.deserialize(io), root, h)
    found || error("blob missing from store: $h")
    return v
end

function _get_txt(root, h)
    found, s = MemoStore.with_blob(io -> read(io, String), root, h)
    found || error("blob missing from store: $h")
    return s
end

"""
    write_chunk!(root, chunk; fn_src, params, keys, setup_src = "", captures = Dict()) -> chunk

Write the descriptor for one chunk of a sweep. `params` and `keys` are parallel: `keys[i]` is the
shard key that `params[i]` produces under `fn_src`.

The closure travels as SOURCE, not as a serialized function. A serialized closure can only be
revived by a process that already has its defining code loaded, which a fresh batch job does not.
Source plus explicitly serialized captures is also what makes the shard key honest: the same text
and the same captured values give the same key on any machine.
"""
function write_chunk!(root::AbstractString, chunk::AbstractString;
                      fn_src::AbstractString, params::AbstractVector,
                      keys::AbstractVector, setup_src::AbstractString = "",
                      captures::AbstractDict = Dict{String,Any}(),
                      summary_src::AbstractString = "", lazy::Bool = false,
                      landed = nothing)
    length(params) == length(keys) ||
        throw(ArgumentError("params and keys must be the same length"))
    fn_h, _ = _put_txt(root, fn_src)
    setup_h = isempty(setup_src) ? "" : first(_put_txt(root, setup_src))
    # Travels as SOURCE for the same reason the body does — a fresh process cannot revive a closure.
    sum_h = isempty(summary_src) ? "" : first(_put_txt(root, summary_src))
    caps = Dict{String,Any}[]
    for (name, v) in captures
        h, n = _put_jls(root, v)
        push!(caps, Dict{String,Any}("name" => String(name), "blob" => h, "bytes" => n))
    end
    # Which of these the store ALREADY has. A shard key is a hash of the body and the parameter
    # point and names no run, so a unit landed by a pilot is the same unit here. Deciding that once,
    # on the hub, is what keeps a compute node from having to ask the store per unit: the node reads
    # its own descriptor and skips what is marked.
    shards = Dict{String,Any}[]
    for (k, p) in zip(keys, params)
        h, _ = _put_jls(root, p)
        d = Dict{String,Any}("key" => String(k), "arg" => h)
        (landed !== nothing && String(k) in landed) && (d["have"] = true)
        push!(shards, d)
    end
    MemoStore.write_manifest(root, chunk, Dict{String,Any}(
        "kind" => KIND_CHUNK,
        "created" => round(Int, time()),
        "julia" => string(VERSION),
        "fn" => fn_h,
        "setup" => setup_h,
        "summary" => sum_h,
        "lazy" => lazy,
        "captures" => caps,
        "shards" => shards))
    return chunk
end

# ── The event log ────────────────────────────────────────────────────────────────────────────
# A chunk reports by CREATING files, never by rewriting one. That is the only shape safe for
# uncoordinated writers on a shared filesystem: `rename` into place is atomic, appends are not
# atomic across NFS clients, and byte-range locks want a lock manager that is often absent. The
# writer's job id is in the name, so two writers cannot collide and nothing has to be locked to
# make that true.
#
# No global sequence number. One would need coordination between writers, which is the thing this
# environment cannot give; and it is not needed, because an event names a single chunk, events for
# different chunks commute, and within a chunk the later timestamp wins.
#
# One file per UNIT is the alternative, and it is the metadata storm the store is laid out to
# avoid: a grid of ten million points is ten million files whatever the chunking.
events_dir(root::AbstractString) = joinpath(root, "events")

# How much a chunk accumulates before it reports. Whichever comes first, so a fast chunk reports by
# volume and a slow one by time, and neither writes a file per unit.
#
# Measured, not guessed: a row carrying a small inline value costs about 0.4 KB and 3.6 us to parse,
# flat from 200 rows to 2000. Parse cost is therefore linear in UNITS whatever the cadence, so the
# figure below buys file count and progress granularity rather than speed. 500 rows is ~200 KB per
# event, which is a comfortable size on a parallel filesystem, and puts a ten million unit sweep at
# twenty thousand events rather than ten million files.
const EVENT_ROWS = 500
const EVENT_SECS = 30.0

# Sortable by name and unique without asking anyone: the writer's clock, then its job id, then a
# counter private to this writer. Padded so lexical order is chronological order.
#
# The counter is not decoration. Two events from one job for one chunk can fall in the same
# millisecond, and a name built from time and job alone then collides: the second write replaces the
# first and takes its rows with it. An immutable log must never overwrite, and a per-writer counter
# is the only tie-break available that needs no coordination.
const _EVENT_SEQ = Ref(0)

event_name(chunk::AbstractString, jobid::AbstractString, at::Real, seq::Integer) =
    string(lpad(round(Int, at * 1000), 15, '0'), "-", jobid, ".", lpad(seq, 6, '0'), "-", chunk)

# What identifies this writer. A scheduler job and array element where there is one, otherwise the
# process, which is enough to keep two local runners apart.
function job_tag()
    jid = get(ENV, "SLURM_JOB_ID", get(ENV, "PBS_JOBID", ""))
    aid = get(ENV, "SLURM_ARRAY_TASK_ID", "")
    isempty(jid) && return string("p", getpid())
    return isempty(aid) ? jid : string(jid, "_", aid)
end

"""
    write_event!(root, chunk, rows; counts...) -> String

Record what this job has finished. `rows` are the unit records completed since this job's last
event, so a reader's fold is a plain union and there is no final event to wait for.
"""
# `ran_on` is WHERE THE WORK RAN, so the writer's own hostname is the right default only because the
# writer is normally the compute node reporting on itself. A fold is the exception: it is written by
# whoever is compacting, and the hub compacting its mirror would otherwise restamp a chunk with the
# laptop's name and report that as the node the units ran on.
function write_event!(root::AbstractString, chunk::AbstractString, rows::AbstractVector;
                      jobid::AbstractString = job_tag(), at::Real = time(),
                      ran_on::Union{Nothing,AbstractString} = nothing, counts...)
    dir = events_dir(root)
    mkpath(dir)
    d = Dict{String,Any}("chunk" => String(chunk), "jobid" => String(jobid),
                         "ts" => round(Int, at),
                         # `nothing` means "whoever is writing", which is the compute node in the
                         # ordinary case. An explicit empty string means "this event says nothing
                         # about where anything ran", which a removal does not.
                         "ran_on" => ran_on === nothing ? _ran_on() : String(ran_on),
                         "units" => collect(rows))
    for (k, v) in counts; d[String(k)] = v; end
    dest = joinpath(dir, event_name(chunk, jobid, at, (_EVENT_SEQ[] += 1)))
    tmp = tempname(dir)
    try
        open(io -> TOML.print(io, d), tmp, "w")
        mv(tmp, dest)          # never `force`: an event that would replace another is a lost record
    catch
        try; rm(tmp; force = true); catch; end
        rethrow()
    end
    return dest
end

"Every event this store holds for `chunk`, oldest first. Names sort chronologically by construction."
function chunk_events(root::AbstractString, chunk::AbstractString)
    dir = events_dir(root)
    isdir(dir) || return String[]
    suf = "-" * String(chunk)
    return sort!(String[joinpath(dir, f) for f in readdir(dir) if endswith(f, suf)])
end

"""
    compact_events!(root; grace = 900.0) -> Int

Fold a chunk's settled events into one and delete the rest, so a store's log does not grow for the
life of the store. `only` restricts it to one chunk. Returns how many files went.

Snapshot first, delete second, so the chunk's rows are complete at every instant. Only events older
than `grace` are removed, because a reader that listed the directory a moment ago may still be
reading them, which is the same window the CAS already leaves around a blob.

Nobody has to run this and nothing waits for it: a store that is never compacted is correct, only
larger. Compute nodes never read another chunk's events, so it cannot disturb a running job.
"""
function compact_events!(root::AbstractString; grace::Real = 900.0, only::AbstractString = "")
    dropped = 0
    now = time()
    for (chunk, paths) in events_by_chunk(root)
        (isempty(only) || chunk == only) || continue
        length(paths) > 1 || continue
        old = String[p for p in paths if now - mtime(p) > grace]
        length(old) > 1 || continue           # nothing to gain from folding one file into one
        rows = collect(values(rows_of(root, old)))
        # Counts come from the ROWS, not from the last event's header. The newest event may be a
        # tombstone, which carries no counts at all, and inheriting those turned a compacted chunk
        # into one that reported nothing done.
        # …and the node comes from the events being folded, for the same reason: the fold describes
        # the work, and the machine doing the folding is not the machine that did the work.
        tot = 0; node = ""; newest = 0.0
        for p in old
            d = try; TOML.parsefile(p); catch; continue; end
            tot = max(tot, Int(get(d, "total", 0)))
            v = String(get(d, "ran_on", ""))
            mt = try; mtime(p); catch; 0.0; end
            if !isempty(v) && mt >= newest; node = v; newest = mt; end
        end
        nfail = count(r -> String(get(r, "status", "")) == "error", rows)
        write_event!(root, chunk, rows; total = max(tot, length(rows)), done = length(rows),
                     ran = length(rows) - nfail, skipped = 0, failed = nfail, at = now,
                     ran_on = node)
        for p in old
            try; rm(p; force = true); dropped += 1; catch; end
        end
    end
    return dropped
end

"""
    events_by_chunk(root) -> Dict{String,Vector{String}}

Every event in the store, grouped by chunk, oldest first. ONE directory listing: a caller walking a
whole sweep would otherwise list the directory once per chunk, which is quadratic in the number of
chunks and is the cost this layout exists to avoid.
"""
function events_by_chunk(root::AbstractString)
    dir = events_dir(root)
    out = Dict{String,Vector{String}}()
    isdir(dir) || return out
    for f in sort!(readdir(dir))
        i = findfirst('-', f); i === nothing && continue
        j = findnext(==('-'), f, i + 1); j === nothing && continue
        push!(get!(out, f[(j + 1):end], String[]), joinpath(dir, f))
    end
    return out
end

"Fold a chunk's events, oldest first, into its unit rows. Upserts apply, then removals."
function rows_of(root::AbstractString, paths)
    out = Dict{String,Any}()
    for p in paths
        d = try; TOML.parsefile(p); catch; continue; end
        for u in get(d, "units", Any[])
            u isa AbstractDict || continue
            k = String(get(u, "key", ""))
            isempty(k) || (out[k] = u)
        end
        for k in get(d, "dropped", Any[])
            delete!(out, String(k))
        end
    end
    return out
end

"The counts the chunk's job last reported: `(; node, ran, failed, skipped, done, total)`."
function chunk_progress(root::AbstractString, paths)
    blank = (; node = "", ran = 0, failed = 0, skipped = 0, done = 0, total = 0)
    isempty(paths) && return blank
    d = try; TOML.parsefile(last(paths)); catch; return blank; end
    # The counts come from the newest event. The NODE does not: not every event is written by the
    # machine that did the work. A tombstone is written by the hub when a failed unit is dropped for
    # a retry, and it is newest by definition, so reading its `ran_on` reported the laptop as the
    # node a cluster chunk ran on. The newest event that actually names one is the answer.
    node = String(get(d, "ran_on", ""))
    if isempty(node)
        for p in Iterators.reverse(collect(paths))
            v = try; String(get(TOML.parsefile(p), "ran_on", "")); catch; ""; end
            isempty(v) || (node = v; break)
        end
    end
    return (; node, ran = Int(get(d, "ran", 0)),
              failed = Int(get(d, "failed", 0)), skipped = Int(get(d, "skipped", 0)),
              done = Int(get(d, "done", 0)), total = Int(get(d, "total", 0)))
end

"""
    chunk_rows(root, chunk) -> Dict{String,Any}

This chunk's unit records keyed by shard key, latest event winning. A retried chunk re-emits the
units it re-ran, so reading in name order and overwriting is the whole merge rule.
"""
# An event is a set of upserts AND a set of removals. Clearing a failed unit for retry has to be
# expressible, and the log is immutable, so it is said in a later event rather than by editing an
# earlier one.
chunk_rows(root::AbstractString, chunk::AbstractString) = rows_of(root, chunk_events(root, chunk))

# Where this task is running, for the DAG's provenance badges. SLURM exports the job and array
# element; without them (a local ExecLauncher run) the hostname alone is the answer.
function _ran_on()
    host = try; gethostname(); catch; "?"; end
    jid = get(ENV, "SLURM_JOB_ID", "")
    aid = get(ENV, "SLURM_ARRAY_TASK_ID", "")
    isempty(jid) && return host
    return isempty(aid) ? "$host/$jid" : "$host/$jid[$aid]"
end

# ── Running ──────────────────────────────────────────────────────────────────────────────────

"A shard is done when its manifest is present. The store is the source of truth, not a job record."
is_done(root::AbstractString, key::AbstractString) = first(result(root, key))

# What a result IS, recorded beside it so the question can be answered without reading it: the
# concrete type, the dimensions, and the stored size. This is what lets a notebook describe a sweep's
# output — and decide whether it wants to fetch any of it — at the cost of a manifest read.
function _shape_of(v, bytes::Integer)
    d = Dict{String,Any}("type" => string(typeof(v)), "bytes" => Int(bytes))
    if v isa AdoptedFile
        # The type name says nothing a reader wants; the file it came from says everything.
        d["type"] = length(v.paths) == 1 ? basename(v.paths[1]) : "$(length(v.paths)) files"
    elseif v isa AbstractArray
        d["dims"] = collect(Int, size(v))
        d["eltype"] = string(eltype(v))
        d["length"] = length(v)
    end
    return d
end

# A summary rides in every manifest read, so it holds facts rather than results: a number, a bool, a
# short string, a small vector, or a named group of those (`(; loss, acc, converged)`). Anything
# larger is dropped rather than truncated — a half-written value is worse than an absent one.
_toml_scalar(x) = x isa Real || x isa Bool || x isa AbstractString
_toml_value(x) = _toml_scalar(x) ? (x isa AbstractString ? String(x) : x) :
                 (x isa AbstractVector && length(x) <= 64 && all(_toml_scalar, x)) ? collect(x) :
                 nothing

function _summarize(f, value)
    v = f === nothing ? value : (try; Base.invokelatest(f, value); catch; return nothing; end)
    flat = _toml_value(v)
    flat === nothing || return flat
    # A NamedTuple or Dict of facts — the shape a run naturally reports (loss, accuracy, a flag).
    pairs = v isa NamedTuple ? zip(string.(keys(v)), values(v)) :
            v isa AbstractDict ? zip(string.(keys(v)), values(v)) : nothing
    pairs === nothing && return nothing
    out = Dict{String,Any}()
    for (k, x) in pairs
        y = _toml_value(x)
        y === nothing || (out[k] = y)
    end
    return isempty(out) ? nothing : out
end

"""
    run_chunk(root, chunk; force = false) -> NamedTuple

Run every shard in `chunk` that is not already in the store. Returns
`(; total, ran, skipped, failed)`.

A shard that throws is recorded as a failed entry and the chunk continues: with thousands of
shards, some failing is the normal case, and one bad parameter must not cost the whole chunk.
"""
# Which unit failed, in the form its author wrote it. `:compact` because a parameter point is a
# label here, and bounded because an argument can be anything a closure was handed — including the
# captured array a log has no business restating.
_arg_label(arg) = first(sprint(show, arg; context = :compact => true), 200)

function run_chunk(root::AbstractString, chunk::AbstractString; force::Bool = false)
    d = MemoStore.read_manifest(root, chunk)
    d === nothing && error("no chunk descriptor for key $chunk under $root")
    get(d, "kind", "") == KIND_CHUNK || error("manifest $chunk is not a $KIND_CHUNK")

    shards = get(d, "shards", Any[])
    total = length(shards)
    ran = 0; skipped = 0; failed = 0
    started = round(Int, time())

    # What this chunk has already recorded. A job that died part way through is retried as the same
    # chunk, and its own events are how it knows what not to redo. Nothing global is consulted:
    # reuse ACROSS runs is the hub's to decide when it writes the descriptor, because a compute node
    # cannot afford a lookup per unit and would have no cheap way to do one.
    have = force ? Dict{String,Any}() : chunk_rows(root, chunk)
    # …and what the hub believed was already in the store when it wrote this descriptor. Without it a
    # full sweep recomputes every unit a pilot had already landed, which is the case the sharing
    # exists for.
    #
    # ADVISORY, not trusted. The mark is a reference to another run's results and nothing protects
    # them: releasing that run, retrying its failures or collecting it as stale all remove them
    # after the mark was written. A mark taken on faith then skips a unit that no longer exists
    # anywhere, and nothing will ever run it — the sweep stops with units that can never land.
    # So a marked unit is confirmed against the store before it is skipped. That costs one fold per
    # JOB, not per unit, and only when there is a mark to check.
    if !force
        marked = String[String(get(sh, "key", "")) for sh in shards
                        if sh isa AbstractDict && get(sh, "have", false) === true]
        filter!(k -> !isempty(k) && !haskey(have, k), marked)
        if !isempty(marked)
            elsewhere = Set{String}()
            for (c, paths) in events_by_chunk(root)
                c == chunk && continue
                for k in Base.keys(rows_of(root, paths)); k in marked && push!(elsewhere, k); end
            end
            for k in marked
                k in elsewhere && (have[k] = Dict{String,Any}("key" => k, "have" => true))
            end
        end
    end
    jobid = job_tag()
    pending = Dict{String,Any}[]
    last_at = Ref(time())

    # Emitting costs a file, so it is paced: often enough that a watcher sees a long chunk moving,
    # rarely enough that a long chunk does not litter the log. Rows accumulate between emissions.
    emit!() = begin
        write_event!(root, chunk, pending; jobid = jobid, total = total,
                     done = ran + skipped + failed, ran = ran, skipped = skipped,
                     failed = failed, started = started)
        empty!(pending)
        last_at[] = time()
    end
    maybe_emit!() = (length(pending) >= EVENT_ROWS || time() - last_at[] >= EVENT_SECS) && emit!()

    emit!()     # the chunk has started, and this is where `ran_on` and `started` are recorded

    # One fresh module per chunk holds the setup and the closure. Shards share it, so a `using` or
    # an expensive constant is paid once per chunk rather than once per shard, which is much of the
    # point of chunking in the first place.
    mod = Module(:SlateShard)
    Core.eval(mod, :(using Base))
    # The shard module starts empty, so anything a closure needs has to be put there explicitly:
    # its captures, whatever `setup_src` defines, and the runner's own API. Without this a shard
    # calling `artifact!` just raises UndefVarError and is recorded as a failed shard, which is
    # a confusing way to learn that a name is missing.
    Core.eval(mod, Expr(:(=), :SlateTask, @__MODULE__))
    Core.eval(mod, Expr(:(=), :artifact!, artifact!))
    # `artifact!` keeps a file whole and opaque; `adopt` reads it and stores it addressably. Both
    # start from a path a unit wrote, so both belong to a shard's vocabulary.
    Core.eval(mod, Expr(:(=), :adopt, adopt))
    # Closed over this chunk's root rather than read from `_ROOT[]`, so `setup_src` can use them too
    # — it is evaluated before any shard runs and `_ROOT[]` is only set inside the shard loop.
    Core.eval(mod, Expr(:(=), :datadir, () -> shard_datadir(root)))
    Core.eval(mod, Expr(:(=), :__slate_dpath, (name) -> shard_dpath(root, name)))
    Core.eval(mod, :(macro sfile(parts...)
        return esc(:(__slate_dpath(joinpath($(parts...)))))
    end))
    setup_h = String(get(d, "setup", ""))
    if !isempty(setup_h)
        Core.eval(mod, Meta.parseall(_get_txt(root, setup_h)))
    end
    for c in get(d, "captures", Any[])
        c isa AbstractDict || continue
        Core.eval(mod, Expr(:(=), Symbol(c["name"]), _get_jls(root, String(c["blob"]))))
    end
    fn = Core.eval(mod, Meta.parse(_get_txt(root, String(d["fn"]))))
    # The per-unit SUMMARY: a small value recorded in the manifest beside `ms` and `status`, so the
    # notebook's live view can plot progress WITHOUT reading a single result blob. Computed here, on
    # the compute node, because the whole point is that the big thing never travels — a sweep whose
    # units return gigabyte fields must still cost only its manifests to watch.
    sum_h = String(get(d, "summary", ""))
    summarize = isempty(sum_h) ? nothing : Core.eval(mod, Meta.parse(_get_txt(root, sum_h)))
    lazy = get(d, "lazy", false) === true

    for s in shards
        s isa AbstractDict || continue
        key = String(get(s, "key", ""))
        isempty(key) && continue
        if haskey(have, key)
            skipped += 1
            continue
        end
        arg = _get_jls(root, String(s["arg"]))
        _ARTIFACTS[] = Dict{String,Any}[]
        _ROOT[] = root
        t0 = time()
        local ok, value, err
        try
            value = Base.invokelatest(fn, arg)
            ok = true
        catch e
            # The traceback matters more than the exception here: the user is looking at one of
            # thousands of shards and needs to know where it went wrong, not just that it did.
            err = sprint(showerror, e, catch_backtrace())
            ok = false
        end
        # `adopt` only means anything on the addressable path. Without `data=auto` the value would be
        # serialized as an inert struct holding a path that does not exist on this machine, which is
        # a failure the reader would meet much later and much further away.
        if ok && value isa AdoptedFile && !lazy
            ok = false
            err = "adopt() stores a file addressably, which this cell did not ask for — " *
                  "add `data=auto` to the cell header."
        end
        ms = (time() - t0) * 1000
        arts = _ARTIFACTS[]
        _ARTIFACTS[] = nothing

        m = Dict{String,Any}(
            "kind" => KIND_SHARD, "created" => round(Int, time()), "julia" => string(VERSION),
            "chunk" => chunk, "ms" => ms, "ran_on" => _ran_on(),
            "status" => ok ? "ok" : "error", "artifacts" => arts)
        if ok
            # Two different questions, recorded separately.
            #
            # `value` is WHAT THE UNIT RETURNED, kept inline whenever it is small enough to carry.
            # That is the sweep's results table, and it must not depend on whether the author also
            # wanted a chart. `summary` is the DERIVED figure `summary =` computes for the progress
            # chart. One field served both before, so `summary = v -> v.snr` on a unit returning
            # `(; snr, sep_px)` silently dropped `sep_px` out of every cheap view of the run: asking
            # for a chart cost you a column, which is not a trade anyone would make on purpose.
            #
            # Both are limited to small TOML-carryable values, and anything larger is dropped rather
            # than stringified — a half-written value is worse than an absent one. The blob below
            # stays authoritative: a TOML round trip does not preserve Julia types (a `Float32`
            # returns as `Float64`), so this is a VIEW of the result, never the result itself.
            iv = _summarize(nothing, value)
            if iv !== nothing
                m["value"] = iv
                # A manifest is TOML and a `Dict` has no order, so the fields came back in whichever
                # order hashing produced — `(; snr, sep_px)` reading back as `(sep_px, snr)`, and a
                # results table whose columns moved between reads. The author's own order is the one
                # that means something, so it is recorded beside the values.
                if value isa NamedTuple && iv isa AbstractDict
                    m["value_keys"] = String[String(k) for k in keys(value) if haskey(iv, String(k))]
                end
            end
            if summarize !== nothing
                sv = _summarize(summarize, value)
                sv === nothing || (m["summary"] = sv)
            end
            # A `data=auto` cell stores the result ADDRESSABLY: chunked and indexed, so the notebook
            # can slice it without moving it. Falls through to the whole-value path for anything with
            # no addressable form, which keeps the attribute a performance choice rather than a
            # constraint on what a unit may return.
            ds = lazy ? write_dataset!(root, value) : nothing
            if ds !== nothing
                idx, n = ds
                m["dataset"] = idx
                m["bindings"] = Any[]
                m["shape"] = _shape_of(value, n)
            else
                codec = _codec_pick(value)
                h, n = MemoStore.put_blob(io -> _codec_encode(io, codec, value), root)
                m["bindings"] = [Dict{String,Any}("name" => "result", "codec" => codec,
                                                  "blob" => h, "bytes" => n)]
                m["shape"] = _shape_of(value, n)
                # WHY this one is not addressable, recorded where the answer is known: on the node,
                # holding the value. The notebook otherwise sees an empty dataset with no way to
                # tell "the cell did not ask" from "this shape has nothing to chunk" — and advised
                # a reset for both, which for the second discards good units and changes nothing.
                #
                # The structural checks only. `dataset_kind` would consult `_ds_arrow`, which
                # IMPORTS Arrow on first use, and a unit that stored whole has no business paying
                # for that to explain itself.
                could = _ds_arrayable(value) || _ds_columns(value) !== nothing
                m["whole"] = !could ? "shape" : (lazy ? "arrow" : "eager")
            end
            ran += 1
        else
            m["bindings"] = Any[]
            m["error"] = err
            failed += 1
            # The failure in the LOG, not only in the unit's row. A reader opening the log — which is
            # the first place anyone looks — found a line saying the chunk had failures and no way to
            # learn what they were.
            #
            # In the MESSAGE rather than a field: a field value is shown with `show`, so the
            # traceback arrives as one line with its newlines escaped. A multi-line message is
            # rendered across `│` continuations, which is a record the viewer can already read.
            #
            # One per failed unit, which is bounded by the breaker rather than by the grid: a sweep
            # failing wholesale is stopped long before every unit has had a turn.
            @error "unit failed: " * err unit = _arg_label(arg)
        end
        m["key"] = key
        push!(pending, m)
        maybe_emit!()
    end

    emit!()
    # Fold this chunk's own log now that it is finished. Bounded work on files this job wrote, no
    # coordination with anyone, and it keeps a chunk that was retried a few times from leaving a
    # pile behind. The grace window protects a reader that listed the directory a moment ago.
    try; compact_events!(root; only = chunk); catch; end
    return (; total, ran, skipped, failed)
end

"""
    result(root, key) -> (found, status, value)

One unit's outcome by key. Folds the store to find it, so it is for asking about a unit or two; a
caller walking many should fold once itself (`events_by_chunk` + `rows_of`) and use `row_result`.
"""
function result(root::AbstractString, key::AbstractString)
    for (_, paths) in events_by_chunk(root)
        r = get(rows_of(root, paths), String(key), nothing)
        r === nothing || return row_result(root, r)
    end
    return (false, "", nothing)
end

"""
    row_result(root, row) -> (found, status, value)

Read one unit's outcome out of its event row. `status` is "ok", "error", or "" when it has not run.
The row is the record the chunk's job wrote; the value still comes from the CAS.
"""
function row_result(root::AbstractString, d)
    d === nothing && return (false, "", nothing)
    st = String(get(d, "status", ""))
    st == "ok" || return (true, st, get(d, "error", nothing))
    bs = get(d, "bindings", Any[])
    isempty(bs) && return (true, st, nothing)
    return (true, st, load_binding(root, bs[1]))
end

"""
    load_binding(root, binding; zc = false) -> value

Materialize one stored binding through the codec it was written with. `zc` mmaps the blob read-only
instead of copying — safe only while nothing mutates the result. `path` overrides where the blob is
read from, which is how a caller reading a store it cannot open supplies a fetched copy.
"""
function load_binding(root::AbstractString, b::AbstractDict; zc::Bool = false,
                      path::AbstractString = "")
    codec = String(get(b, "codec", "jls"))
    p = isempty(path) ? MemoStore.blob_path(root, String(b["blob"])) : String(path)
    return _codec_decode(codec, p, zc)
end

# ── Reading a dataset back ───────────────────────────────────────────────────────────────────
# Every read here is BOUNDED by the slice it was asked for. The index says which bytes matter; only
# those are touched. An array slice mmaps the blob and copies out the requested range, so the pages
# outside it are never faulted in; a table slice opens only the chunks the rows fall in.

"Elements `i` (linear) of an array dataset. Reads exactly that range's bytes."
function dataset_elements(root::AbstractString, index::AbstractDict, i::AbstractUnitRange)
    blob, off, _, n = array_range(index, i)
    T = eltype_of(String(index["eltype"]))
    path = MemoStore.blob_path(root, blob)
    io = open(path, "r")
    try
        # An mmap of just this window: `Mmap.mmap` takes a byte offset, so nothing before `off` is
        # mapped and nothing after `n` elements is read. The copy hands back ordinary memory.
        return copy(Mmap.mmap(io, Vector{T}, n, off))
    finally
        close(io)
    end
end

# The Arrow-side half of one chunk read, kept as its own function so the world-age boundary in
# `dataset_rows` is a single `invokelatest` around everything that touches an Arrow value.
# `collect` is what makes the result ordinary memory the caller owns.
_read_chunk(A, path, want, lo, hi) =
    (t = A.Table(path); [collect(getproperty(t, Symbol(nm))[lo:hi]) for nm in want])

"""
    dataset_rows(root, index, rows; select, blobpath) -> NamedTuple of columns

Rows `rows` of a table dataset. Opens only the chunks they fall in, and only the columns named.

`blobpath(hash, bytes) -> path` resolves a chunk to something Arrow can open; the default is the
blob's place in the local store. A store the hub cannot see supplies its own resolver, which is
where a remote fetch happens — the chunk is the unit of addressability either way, so what changes
is how one arrives, not how many.
"""
function dataset_rows(root::AbstractString, index::AbstractDict, rows::AbstractUnitRange;
                      select = nothing,
                      blobpath = (h, _) -> MemoStore.blob_path(root, h))
    A = _ds_arrow()
    A === nothing && error("reading a table dataset needs Arrow available in this environment — " *
                           "add it to the notebook (`slate_pkg(op = \"add\", name = \"Arrow\")`)")
    names = String[String(c) for c in index["columns"]]
    want = select === nothing ? names : String[String(s) for s in select]
    bad = setdiff(want, names)
    isempty(bad) || error("no such column(s) in this dataset: " * join(bad, ", "))
    parts = [Vector{Any}() for _ in want]
    sizes = Dict{String,Int}(String(c["blob"]) => Int(c["bytes"])
                             for c in get(index, "chunks", Any[]))
    for (_, blob, lo, hi) in table_chunks(index, rows)
        # ONE world-age boundary per chunk, not per operation. Arrow may have been imported after
        # this function was compiled (see `_ds_arrow`), which makes every one of its methods — down
        # to `size` on a column — unreachable from here. Everything that touches an Arrow value
        # therefore happens inside this closure, which `invokelatest` runs in the current world, and
        # what comes back out is ordinary `Vector`s.
        #
        # `Arrow.Table` mmaps, so only the pages behind the columns and rows named here fault in.
        cols = _arrow_call(_read_chunk, A, blobpath(blob, get(sizes, blob, 0)), want, lo, hi)
        for (j, c) in enumerate(cols); append!(parts[j], c); end
    end
    return NamedTuple{Tuple(Symbol.(want))}(Tuple(
        (isempty(p) ? p : identity.(p)) for p in parts))
end

"Every artifact a shard registered, as `(name, blob, bytes)` rows. Blobs stay where they are."
function artifacts(root::AbstractString, key::AbstractString)
    for (_, paths) in events_by_chunk(root)
        d = get(rows_of(root, paths), String(key), nothing)
        d === nothing && continue
        return [x for x in get(d, "artifacts", Any[]) if x isa AbstractDict]
    end
    return Dict{String,Any}[]
end

"""
    row_bytes(root, row) -> Int

What a unit costs the store: the blobs its row names. There is no per-unit manifest to charge for,
so unlike `MemoStore.entry_bytes` this is the blobs alone.
"""
function row_bytes(root::AbstractString, d)
    d === nothing && return 0
    b = 0
    for h in MemoStore._manifest_blobs(d)
        p = MemoStore.blob_path(root, h); isfile(p) && (b += Int(filesize(p)))
    end
    return b
end

# ── What a job's output looks like ───────────────────────────────────────────────────────────
# A unit writes with `@info` / `@warn` / `@error`, and this is what makes that worth recommending.
# Julia's default logger against a FILE gives no colour and no time, which is most of what a batch
# log is read for: a job that ran for six hours needs to say when each thing happened, and a reader
# scanning megabytes needs the level to be visible without reading the sentence.
#
#     ┌ Info 14:22:31.004: processed 1200 records
#     │   batch = 3
#     └ @ Main run.jl:12
#
# The level stays first, immediately after the box character, because that is what the viewer's
# filter reads and what the eye lands on. The DATE is not on every record — it is the header line
# below, printed once, since a per-record date is ten characters of the same thing on every line.
_log_clock() = Dates.format(Dates.now(), "HH:MM:SS.sss")

function _task_logger(io::IO = stderr)
    # `:color => true` unconditionally: the stream IS a file, so nothing can detect a terminal here,
    # and the viewer renders the codes. `log_stat`-driven reading strips them for classification.
    # `Info`, not `Debug`: a floor of Debug enables debug logging in every package the unit loads,
    # and a job's output is already the largest thing it produces. A body that wants its own debug
    # records asks for them with its own `with_logger`.
    return Logging.ConsoleLogger(IOContext(io, :color => true), Logging.Info;
        meta_formatter = (lvl, _mod, _grp, _id, file, line) -> begin
            c = lvl < Logging.Info  ? :light_black :
                lvl < Logging.Warn  ? :cyan :
                lvl < Logging.Error ? :yellow : :red
            name = lvl < Logging.Info ? "Debug" : lvl < Logging.Warn ? "Info" :
                   lvl < Logging.Error ? "Warning" : "Error"
            return c, "$(name) $(_log_clock()):", "@ $(_mod) $(basename(String(file))):$(line)"
        end)
end

"""
    main(args = ARGS)

Entry point for the process a scheduler starts: `julia --project=<env> slatetask.jl <root> <chunk>`.
Exits nonzero only when the chunk itself could not run; individual shard failures are recorded in
the store and are not an error at this level.
"""
function main(args = ARGS)
    length(args) >= 2 ||
        (println(stderr, "usage: slatetask.jl <cas-root> <chunk-key>..."); return 2)
    root = String(args[1])
    # Slate's own lines go through the same logger as the body's, so one log has one shape.
    # Did anything this process attempted actually work? `ran` counts the units that SUCCEEDED and
    # `failed` the ones that did not, so what was attempted is their sum — a chunk that skipped its
    # units (they were already in the store) attempted nothing and proves nothing either way.
    tried = 0; worked = 0
    Logging.with_logger(_task_logger()) do
        @info "task starting" at = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS") host = gethostname() julia = string(VERSION) chunks = length(args) - 1
        # Several chunks per process, run one after another. A process is expensive (a whole Julia
        # start plus package loads), so the alternative — one process per chunk — is both slow and,
        # run locally, a fast route to exhausting memory.
        for chunk in args[2:end]
            r = run_chunk(root, String(chunk))
            tried += r.ran + r.failed; worked += r.ran
            # The failure count leads when it is non-zero: it is the number a reader is looking for,
            # and the level makes the line findable by the viewer's filter without reading it.
            if r.failed > 0
                @error "chunk finished with failures" chunk ran = r.ran skipped = r.skipped failed = r.failed total = r.total
            else
                @info "chunk finished" chunk ran = r.ran skipped = r.skipped failed = r.failed total = r.total
            end
        end
    end
    # Nonzero when everything this process RAN failed. Individual failures stay a store fact — a
    # sweep is expected to have some — but a chunk where nothing worked is a failed chunk, and that
    # has to be visible as an exit status: it is the only thing a scheduler can read, and what lets
    # the rest of a sweep be queued behind the first chunk with `--dependency=afterok`.
    return (tried > 0 && worked == 0) ? 1 : 0
end

end # module SlateTask
