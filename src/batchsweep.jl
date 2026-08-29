# The reconciler: the part that makes a sweep survive the hub being closed for a day.
#
# It stores no job state of its own. Given a sweep it recomputes what should exist, reads what does
# exist, and submits the difference. Every question it asks has a durable answer:
#
#   is this shard finished?   the store has a manifest for its key
#   is this chunk in flight?  the scheduler has a live job whose index file lists it
#   did it fail?              the shard's manifest says status = "error"
#
# None of those depend on the hub having been running when anything happened, which is why closing
# the notebook, restarting Slate, rebooting, or opening the notebook on another machine all reduce
# to the same code path: reconcile and render.
#
# Reconciliation is idempotent, so crashing partway through submission is harmless, and calling it
# on a loop is the normal mode of operation rather than a recovery procedure.

if !isdefined(@__MODULE__, :MemoStore)
    include(joinpath(@__DIR__, "memostore.jl"))
end
if !isdefined(@__MODULE__, :SlateTask)
    include(joinpath(@__DIR__, "slatetask.jl"))
end
if !isdefined(@__MODULE__, :BatchLauncher)
    include(joinpath(@__DIR__, "batchlauncher.jl"))
end

module BatchSweep

import SHA
import TOML

const P = parentmodule(@__MODULE__)
const MemoStore = P.MemoStore
const SlateTask = P.SlateTask
const BatchLauncher = P.BatchLauncher

const KIND_SWEEP = "slate-sweep"

# ── Sweep descriptors ────────────────────────────────────────────────────────────────────────

"""
    write_sweep!(root, sweep, chunks) -> sweep

Record which chunks make up a sweep. The chunk descriptors themselves already list their shards, so
this is the only extra bookkeeping a sweep needs.
"""
function write_sweep!(root::AbstractString, sweep::AbstractString, chunks)
    MemoStore.write_manifest(root, sweep, Dict{String,Any}(
        "kind" => KIND_SWEEP,
        "created" => round(Int, time()),
        "chunks" => String.(collect(chunks))))
    return sweep
end

function sweep_chunks(root::AbstractString, sweep::AbstractString)
    d = MemoStore.read_manifest(root, sweep)
    d === nothing && error("no sweep descriptor for key $sweep under $root")
    get(d, "kind", "") == KIND_SWEEP || error("manifest $sweep is not a $KIND_SWEEP")
    return String.(get(d, "chunks", String[]))
end

function chunk_shards(root::AbstractString, chunk::AbstractString)
    d = MemoStore.read_manifest(root, chunk)
    d === nothing && return String[]
    return [String(s["key"]) for s in get(d, "shards", Any[]) if s isa AbstractDict && haskey(s, "key")]
end

# ── Submissions ──────────────────────────────────────────────────────────────────────────────
# A submission covers a SET of chunks as one array job, and is named by a digest of that set. The
# name is therefore content-derived like everything else: the same missing work always produces the
# same name, which is what lets `--dependency=singleton` refuse a duplicate that a restarted hub
# would otherwise create.
#
# The index file mapping array element to chunk has to exist anyway, because the job reads it to
# find its own work. Reading it back is how the reconciler learns which chunks a live submission
# covers, so tracking that costs nothing extra.
submission_name(chunks) =
    "slate-" * first(bytes2hex(SHA.sha256(join(sort(String.(collect(chunks))), '\n'))), 16)

jobs_dir(root) = joinpath(root, "jobs")
index_path(root, name) = joinpath(jobs_dir(root), name * ".index")

"Every submission with an index file on disk, as `name => chunks`. One directory listing."
function known_submissions(root::AbstractString)
    dir = jobs_dir(root)
    out = Dict{String,Vector{String}}()
    isdir(dir) || return out
    for f in readdir(dir; join = true)
        endswith(f, ".index") || continue
        name = basename(f)[1:end-length(".index")]
        out[name] = try
            String.(split(read(f, String); keepempty = false))
        catch
            String[]
        end
    end
    return out
end

# ── Plan ─────────────────────────────────────────────────────────────────────────────────────

"""
    Plan

What a sweep looks like right now. `chunk_state` is one of `:done`, `:running`, `:pending`,
`:missing`; `to_submit` is what a reconcile would send.
"""
struct Plan
    sweep::String
    shards_total::Int
    shards_done::Int
    shards_ok::Int
    shards_failed::Int
    chunk_state::Dict{String,Symbol}
    to_submit::Vector{String}
end

fraction(p::Plan) = p.shards_total == 0 ? 1.0 : p.shards_done / p.shards_total
is_complete(p::Plan) = p.shards_done == p.shards_total && isempty(p.to_submit)

function Base.show(io::IO, p::Plan)
    print(io, "Plan($(p.sweep): $(p.shards_done)/$(p.shards_total) shards")
    p.shards_failed > 0 && print(io, ", $(p.shards_failed) failed")
    isempty(p.to_submit) || print(io, ", $(length(p.to_submit)) chunks to submit")
    print(io, ")")
end

"""
    plan(root, sweep; launcher = nothing) -> Plan

Read the world and work out what is left. With a `launcher`, chunks covered by a live submission
are reported as `:running`/`:pending` and are NOT queued for resubmission; without one, every
unfinished chunk looks `:missing`, which is the correct answer when there is no scheduler to ask.

A partially finished chunk counts as missing. Resubmitting it is cheap and safe because the runner
skips shards that are already in the store, so a chunk killed at 90% resumes rather than repeats.
"""
function plan(root::AbstractString, sweep::AbstractString; launcher = nothing)
    chunks = sweep_chunks(root, sweep)

    total = 0; done = 0; ok = 0; failed = 0
    chunk_done = Dict{String,Bool}()
    for c in chunks
        shards = chunk_shards(root, c)
        total += length(shards)
        ndone = 0
        for k in shards
            m = MemoStore.read_manifest(root, k)
            m === nothing && continue
            ndone += 1
            String(get(m, "status", "")) == "error" ? (failed += 1) : (ok += 1)
        end
        done += ndone
        chunk_done[c] = !isempty(shards) && ndone == length(shards)
    end

    # Which chunks are covered by something the scheduler still has. One poll for the whole sweep.
    live = Dict{String,Symbol}()
    if launcher !== nothing
        subs = known_submissions(root)
        names = collect(keys(subs))
        if !isempty(names)
            states = BatchLauncher.poll(launcher, root, names)
            for (name, st) in states
                st === :unknown && continue
                for c in get(subs, name, String[])
                    # running beats pending when a chunk appears in more than one submission
                    (get(live, c, :pending) === :running) || (live[c] = st)
                end
            end
        end
    end

    state = Dict{String,Symbol}()
    to_submit = String[]
    for c in chunks
        if get(chunk_done, c, false)
            state[c] = :done
        elseif haskey(live, c)
            state[c] = live[c]
        else
            state[c] = :missing
            push!(to_submit, c)
        end
    end

    return Plan(String(sweep), total, done, ok, failed, state, to_submit)
end

"""
    reconcile!(root, sweep, launcher, specfn; submit = true, cap = 0) -> Plan

Bring the sweep closer to done: work out what is missing and submit exactly that. `specfn(name,
chunks)` builds the `JobSpec`, so this module never has to know about partitions, walltimes, or
Julia paths.

`cap` refuses a submission larger than the given number of chunks, returning the plan unsubmitted.
Firing thousands of jobs should take an explicit decision, not happen because a key changed.
"""
function reconcile!(root::AbstractString, sweep::AbstractString, launcher, specfn;
                    submit::Bool = true, cap::Integer = 0)
    p = plan(root, sweep; launcher)
    (isempty(p.to_submit) || !submit) && return p
    cap > 0 && length(p.to_submit) > cap &&
        error("sweep $sweep wants to submit $(length(p.to_submit)) chunks, over the cap of $cap")

    name = submission_name(p.to_submit)
    mkpath(jobs_dir(root))
    # Write the index BEFORE submitting. If the submit succeeds and the hub dies before it could
    # record anything, the index is already on disk and the next reconcile sees the work as live
    # instead of submitting it a second time.
    write(index_path(root, name), join(p.to_submit, "\n") * "\n")
    try
        BatchLauncher.submit!(launcher, specfn(name, p.to_submit))
    catch e
        rm(index_path(root, name); force = true)   # nothing is live; let the next pass retry
        rethrow(e)
    end
    return plan(root, sweep; launcher)
end

# ── Progress ─────────────────────────────────────────────────────────────────────────────────

"""
    progress(root, sweep) -> (; total, done, ran, skipped, failed, chunks, ran_on)

Live progress from the per-chunk status files, which is finer than the store alone can give: a
chunk that is 30 shards into 50 has written a status file but no new manifests since its last
completed shard.

One directory listing, then a read of the files that belong to this sweep. Polling per shard would
put a metadata storm on a filesystem shared with the rest of the site.
"""
function progress(root::AbstractString, sweep::AbstractString)
    want = Set(sweep_chunks(root, sweep))
    dir = SlateTask.status_dir(root)
    total = 0; done = 0; ran = 0; skipped = 0; failed = 0
    seen = 0; hosts = String[]
    if isdir(dir)
        for f in readdir(dir; join = true)
            endswith(f, ".toml") || continue
            chunk = basename(f)[1:end-length(".toml")]
            chunk in want || continue
            d = try; TOML.parsefile(f); catch; continue; end
            seen += 1
            total   += Int(get(d, "total", 0))
            done    += Int(get(d, "done", 0))
            ran     += Int(get(d, "ran", 0))
            skipped += Int(get(d, "skipped", 0))
            failed  += Int(get(d, "failed", 0))
            h = String(get(d, "ran_on", "")); isempty(h) || push!(hosts, h)
        end
    end
    return (; total, done, ran, skipped, failed, chunks = seen, ran_on = unique(hosts))
end

"""
    results(root, sweep) -> Vector{NamedTuple}

Every shard of a sweep in order: `(; key, status, value, ran_on, ms)`. A shard that has not run
yet has `status = ""` and `value = nothing`, so the caller can render a partially complete sweep
without deciding what "missing" looks like.
"""
function results(root::AbstractString, sweep::AbstractString)
    out = NamedTuple[]
    for c in sweep_chunks(root, sweep), k in chunk_shards(root, c)
        m = MemoStore.read_manifest(root, k)
        if m === nothing
            push!(out, (; key = k, status = "", value = nothing, ran_on = "", ms = 0.0))
            continue
        end
        _, st, v = SlateTask.result(root, k)
        push!(out, (; key = k, status = st, value = v,
                    ran_on = String(get(m, "ran_on", "")), ms = Float64(get(m, "ms", 0.0))))
    end
    return out
end

"Shards that failed, with their error text — the answer to \"which of my 10,000 jobs broke\"."
failures(root::AbstractString, sweep::AbstractString) =
    [(; r.key, error = r.value) for r in results(root, sweep) if r.status == "error"]

end # module BatchSweep
