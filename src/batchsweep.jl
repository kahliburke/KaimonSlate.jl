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

# `Base.include(@__MODULE__, …)` rather than a bare `include`: this file is loaded into a notebook's
# module as well as into Main, and a module built programmatically (as a notebook's is) has no
# `include` of its own.
if !isdefined(@__MODULE__, :MemoStore)
    Base.include(@__MODULE__, joinpath(@__DIR__, "memostore.jl"))
end
if !isdefined(@__MODULE__, :SlateTask)
    Base.include(@__MODULE__, joinpath(@__DIR__, "slatetask.jl"))
end
if !isdefined(@__MODULE__, :BatchLauncher)
    Base.include(@__MODULE__, joinpath(@__DIR__, "batchlauncher.jl"))
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

# Per-chunk submission counts.
#
# This cannot be derived from the index files: a submission is NAMED by a digest of its chunk set,
# so resubmitting the same missing chunks deliberately reuses the same name and overwrites the same
# index. That is what makes `--dependency=singleton` refuse duplicates, and it is also why attempts
# need their own record. One small file, rewritten atomically, on the shared filesystem so the
# count survives the hub going away.
attempts_path(root) = joinpath(jobs_dir(root), "attempts.toml")

function read_attempts(root::AbstractString)
    p = attempts_path(root)
    isfile(p) || return Dict{String,Int}()
    d = try; TOML.parsefile(p); catch; return Dict{String,Int}(); end
    return Dict{String,Int}(String(k) => Int(v) for (k, v) in d if v isa Integer)
end

function bump_attempts!(root::AbstractString, chunks)
    mkpath(jobs_dir(root))
    a = read_attempts(root)
    for c in chunks; a[String(c)] = get(a, String(c), 0) + 1; end
    dir = jobs_dir(root); tmp = tempname(dir)
    try
        open(io -> TOML.print(io, Dict{String,Any}(k => v for (k, v) in a)), tmp, "w")
        mv(tmp, attempts_path(root); force = true)
    catch
        try; rm(tmp; force = true); catch; end
        rethrow()
    end
    return a
end

# ── Cancellation ─────────────────────────────────────────────────────────────────────────────
# A user-requested stop is DURABLE, like everything else here: a marker on the shared filesystem,
# not a flag in the hub. Otherwise closing the notebook would silently un-cancel the sweep, and the
# next reconcile would cheerfully resubmit the work someone just stopped.
cancel_path(root, sweep) = joinpath(jobs_dir(root), sweep * ".cancelled")

is_cancelled(root::AbstractString, sweep::AbstractString) = isfile(cancel_path(root, sweep))

"""
    cancel!(root, sweep, launcher) -> Int

Stop a sweep at the user's request: kill anything live and record the stop so it survives a
restart. Finished units are kept, so resuming later costs only what is left.
"""
function cancel!(root::AbstractString, sweep::AbstractString, launcher)
    n = 0
    try
        subs = known_submissions(root)
        want = Set(sweep_chunks(root, sweep))
        names = [nm for (nm, cs) in subs if any(in(want), cs)]
        isempty(names) || (n = BatchLauncher.cancel!(launcher, root, names))
    catch
        # Best effort: the marker matters more than reaping every job, and a scheduler that is
        # briefly unreachable must not leave the sweep looking live.
    end
    mkpath(jobs_dir(root))
    write(cancel_path(root, sweep), string(round(Int, time())))
    return n
end

"Clear a user-requested stop so the sweep can be submitted again. Returns whether one was set."
function resume!(root::AbstractString, sweep::AbstractString)
    p = cancel_path(root, sweep)
    isfile(p) || return false
    rm(p; force = true)
    return true
end

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

# How many times a chunk may be submitted before the sweep stops retrying it on its own. A shard
# killed by walltime, an OOM, or a dead node writes NO manifest, so it is indistinguishable from one
# that was never attempted: without a budget the reconciler would resubmit it forever, which on a
# shared cluster is a good way to lose an account.
const MAX_ATTEMPTS = 3

"""
    Plan

What a sweep looks like right now.

`chunk_state` is `:done`, `:running`, `:pending`, `:missing`, or `:stalled` (attempted up to the
budget and still not finished, so nothing more will be submitted without being asked).

`state` is the sweep as a whole. "Not progressing" is not one condition, and the differences decide
what to do about it:

  :pending    work remains and nothing is in flight. A reconcile will submit it
  :running    work is queued or executing on the scheduler
  :succeeded  every unit finished, all of them ok
  :partial    every unit finished, some returned an error. A real, common, FINISHED outcome
  :blocked    STOPPED BY ERROR — the breaker tripped because the work itself is failing. Fix the
              body, then reset
  :cancelled  STOPPED BY REQUEST — someone asked it to stop. Nothing is wrong; resume when ready
  :exhausted  units are missing, nothing is in flight, and the retry budget is spent. Something
              about the work outruns its resources. Raise the walltime or memory, then reset

Note that a sweep which has merely stopped PRODUCING is none of these: it is still `:running`, and
the suspicion is reported by `stalled_for` instead. Work can sit queued for hours without finishing
a unit and be perfectly healthy, so "nothing has completed lately" is an observation about a running
sweep, not a state of its own.
"""
struct Plan
    sweep::String
    shards_total::Int
    shards_done::Int
    shards_ok::Int
    shards_failed::Int
    shards_missing::Int
    chunk_state::Dict{String,Symbol}
    chunk_attempts::Dict{String,Int}
    to_submit::Vector{String}
    state::Symbol
    blocked::String            # why nothing more will be submitted ("" = not blocked)
end

# Early-failure circuit breaker. The failure this exists to prevent is submitting thousands of units
# of work, waiting a day, and finding out the body was broken all along — so a run that is failing
# early stops itself rather than spending the rest of the allocation proving the same point.
#
# Absolute AND proportional: a handful of bad parameters in a large sweep is normal and must not trip
# it, while everything failing must trip it whatever the sweep's size.
#
# `probe_chunks` is what makes the breaker actually work. Checking the failure rate is useless if
# every chunk is submitted at once: nothing has finished at submit time, so there is no evidence to
# judge, and by the time there is, the whole sweep has already run. So a sweep with no completed
# units yet releases only its first few chunks, and the rest goes out once those have reported.
# This is the "run a small test before scaling up" habit, made automatic.
Base.@kwdef struct FailurePolicy
    min_sample::Int = 8        # decide nothing before this many units have finished
    max_fraction::Float64 = 0.5
    max_failures::Int = 0      # 0 = no absolute cap
    probe_chunks::Int = 1      # chunks to release before ANY unit has finished (0 = no probing)
end

function _breaker(pol::FailurePolicy, done::Int, failed::Int)
    pol.max_failures > 0 && failed >= pol.max_failures &&
        return "$(failed) units failed, at or past the limit of $(pol.max_failures)"
    done >= pol.min_sample && failed / done > pol.max_fraction &&
        return "$(failed) of the first $(done) units failed " *
               "($(round(Int, 100 * failed / done))%, over the $(round(Int, 100 * pol.max_fraction))% limit)"
    return ""
end

fraction(p::Plan) = p.shards_total == 0 ? 1.0 : p.shards_done / p.shards_total

"Every shard reached a terminal state. Errors count: a sweep with failures IS finished."
is_settled(p::Plan) = p.shards_done == p.shards_total

"Finished and clean. Use `is_settled` when a sweep with recorded failures should also count."
is_complete(p::Plan) = is_settled(p) && p.shards_failed == 0

"""Nothing more will happen without a decision. Covers all three ways a sweep stops short: the work
is failing (`:blocked`), someone stopped it (`:cancelled`), or it outran its resources
(`:exhausted`). A merely idle run is NOT stuck — see `stalled_for`."""
is_stuck(p::Plan) = p.state === :exhausted || p.state === :blocked || p.state === :cancelled

function Base.show(io::IO, p::Plan)
    print(io, "Plan($(p.sweep) $(p.state): $(p.shards_done)/$(p.shards_total) shards")
    p.shards_failed  > 0 && print(io, ", $(p.shards_failed) errored")
    p.shards_missing > 0 && print(io, ", $(p.shards_missing) missing")
    isempty(p.to_submit) || print(io, ", $(length(p.to_submit)) to submit")
    isempty(p.blocked)   || print(io, " — BLOCKED: ", p.blocked)
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
function plan(root::AbstractString, sweep::AbstractString; launcher = nothing,
              max_attempts::Integer = MAX_ATTEMPTS,
              failure_policy::FailurePolicy = FailurePolicy())
    chunks = sweep_chunks(root, sweep)
    subs = known_submissions(root)
    counts = read_attempts(root)
    tries = Dict{String,Int}(c => get(counts, c, 0) for c in chunks)

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

    # Checked before the submit list is built, so a tripped breaker blocks the work rather than
    # reporting it after the fact.
    blocked = _breaker(failure_policy, done, failed)
    cancelled = is_cancelled(root, sweep)

    cstate = Dict{String,Symbol}()
    to_submit = String[]
    for c in chunks
        if get(chunk_done, c, false)
            cstate[c] = :done
        elseif haskey(live, c)
            cstate[c] = live[c]
        elseif cancelled
            cstate[c] = :cancelled
        elseif !isempty(blocked)
            cstate[c] = :blocked
        elseif tries[c] >= max_attempts
            # Attempted its full budget and still not finished. Something about the work outruns
            # its resources (walltime, memory), and resubmitting on a loop would keep burning
            # allocation to prove it.
            cstate[c] = :exhausted
        else
            cstate[c] = :missing
            push!(to_submit, c)
        end
    end

    missing_shards = total - done
    anylive = any(s -> s === :running || s === :pending, values(cstate))
    sweep_state = if total == 0
        :pending
    elseif done == total
        # Every shard reached a terminal state. Errors do not make this "still going": a sweep that
        # finished with 12 of 4,000 failing is DONE, and saying otherwise would leave it looking
        # forever in progress.
        failed == 0 ? :succeeded : :partial
    elseif cancelled
        # Someone asked it to stop. Nothing is wrong, and it is resumable.
        :cancelled
    elseif !isempty(blocked)
        # The WORK is failing. Continuing would spend an allocation confirming it.
        :blocked
    elseif anylive
        :running
    elseif !isempty(to_submit)
        # Work remains and the budget allows it, but nothing is on the scheduler yet. Distinct from
        # :running, which is what a progress display has to be able to say honestly.
        :pending
    else
        # Units are missing, nothing is in flight, and the retry budget is gone.
        :exhausted
    end

    return Plan(String(sweep), total, done, ok, failed, missing_shards,
                cstate, tries, to_submit, sweep_state, blocked)
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
                    submit::Bool = true, cap::Integer = 0,
                    failure_policy::FailurePolicy = FailurePolicy())
    p = plan(root, sweep; launcher, failure_policy)
    # A tripped breaker produces an empty submit list, so this is belt and braces; being explicit
    # keeps it true if the plan's ordering ever changes.
    # A cancelled sweep must not be resurrected by the next reconcile — that is the whole point of
    # the marker being durable rather than a flag in the hub.
    (p.state === :cancelled || !isempty(p.blocked)) && return p
    (isempty(p.to_submit) || !submit) && return p
    cap > 0 && length(p.to_submit) > cap &&
        error("sweep $sweep wants to submit $(length(p.to_submit)) chunks, over the cap of $cap")

    # Probe wave: with nothing finished yet there is no evidence the body works, so release only a
    # few chunks. The next reconcile either trips the breaker or sends the rest.
    outgoing = p.to_submit
    if failure_policy.probe_chunks > 0 && p.shards_done == 0 &&
       length(outgoing) > failure_policy.probe_chunks
        outgoing = first(outgoing, failure_policy.probe_chunks)
    end

    name = submission_name(outgoing)
    mkpath(jobs_dir(root))
    # Write the index BEFORE submitting. If the submit succeeds and the hub dies before it could
    # record anything, the index is already on disk and the next reconcile sees the work as live
    # instead of submitting it a second time.
    write(index_path(root, name), join(outgoing, "\n") * "\n")
    try
        BatchLauncher.submit!(launcher, specfn(name, outgoing))
        bump_attempts!(root, outgoing)             # only a submission that actually went out counts
    catch e
        rm(index_path(root, name); force = true)   # nothing is live; let the next pass retry
        rethrow(e)
    end
    return plan(root, sweep; launcher, failure_policy)
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

# ── Telemetry ────────────────────────────────────────────────────────────────────────────────
# The numbers that answer the questions a long run actually raises: is it working, how far along,
# how much longer, and has it quietly stopped. An elapsed-seconds counter answers none of them.

"""
    Telemetry

`rate` is measured completions per second, so the ETA self-corrects instead of trusting a per-unit
estimate. `idle_s` is the age of the most recent completion and is the "has it stopped" signal:
distinct from `:stalled`, which is structural (retry budget spent), because work can be legitimately
queued for hours without a single completion.
"""
struct Telemetry
    state::Symbol
    total::Int
    done::Int
    ok::Int
    failed::Int
    missing::Int
    elapsed_s::Float64       # since the first unit finished
    rate_per_s::Float64      # completions per wall second
    eta_s::Float64           # -1.0 when not yet estimable
    idle_s::Float64          # since the most recent completion; -1.0 if nothing has finished
    mean_unit_s::Float64     # mean COMPUTE time per unit (not wall time)
    hosts::Vector{String}
    blocked::String          # why nothing more will be submitted ("" = not blocked)
end

fraction(t::Telemetry) = t.total == 0 ? 1.0 : t.done / t.total

"""
    telemetry(root, sweep; launcher = nothing, plan = nothing) -> Telemetry

Progress with an honest ETA. Derived entirely from the store, so it is correct after a restart and
needs no record of what the hub saw last time.
"""
function telemetry(root::AbstractString, sweep::AbstractString;
                   launcher = nothing, plan = nothing)
    p = plan === nothing ? BatchSweep.plan(root, sweep; launcher) : plan
    created = Float64[]; comp_ms = Float64[]; hosts = String[]
    for c in sweep_chunks(root, sweep), k in chunk_shards(root, c)
        m = MemoStore.read_manifest(root, k)
        m === nothing && continue
        push!(created, Float64(get(m, "created", 0)))
        push!(comp_ms, Float64(get(m, "ms", 0.0)))
        h = String(get(m, "ran_on", "")); isempty(h) || push!(hosts, h)
    end

    now = time()
    if isempty(created)
        return Telemetry(p.state, p.shards_total, 0, 0, 0, p.shards_missing,
                         0.0, 0.0, -1.0, -1.0, 0.0, String[], p.blocked)
    end
    first_done = minimum(created); last_done = maximum(created)
    elapsed = max(now - first_done, 0.0)
    idle = max(now - last_done, 0.0)
    # Rate over the span of observed completions, not since submission: queue time is not throughput
    # and including it would make the ETA pessimistic by however long the job waited.
    span = max(last_done - first_done, 1.0)
    rate = length(created) > 1 ? (length(created) - 1) / span : 0.0
    remaining = max(p.shards_total - p.shards_done, 0)
    eta = (rate > 0 && remaining > 0) ? remaining / rate : (remaining == 0 ? 0.0 : -1.0)

    return Telemetry(p.state, p.shards_total, p.shards_done, p.shards_ok, p.shards_failed,
                     p.shards_missing, elapsed, rate, eta, idle,
                     isempty(comp_ms) ? 0.0 : sum(comp_ms) / length(comp_ms) / 1000,
                     unique(hosts), p.blocked)
end

"""
    stalled_for(t; factor = 6.0, floor_s = 60.0) -> Float64

How long the sweep has looked stopped, or `0.0` if it looks healthy. A run is only suspicious once
it has been idle for several times its own unit duration, so a sweep of slow units is not
constantly accused of hanging. Returns 0 when nothing has completed yet, since a queued sweep has
not started rather than stopped.
"""
function stalled_for(t::Telemetry; factor::Real = 6.0, floor_s::Real = 60.0)
    # A sweep that has stopped on purpose (breaker, cancellation) or given up (:exhausted) is not
    # "possibly stuck": nothing is running because nothing is supposed to be, and saying otherwise
    # sends someone looking for a scheduler fault that does not exist.
    (t.state === :blocked || t.state === :cancelled || t.state === :exhausted) && return 0.0
    (t.idle_s < 0 || t.done == 0 || t.done == t.total) && return 0.0
    threshold = max(factor * max(t.mean_unit_s, 1.0), floor_s)
    return t.idle_s > threshold ? t.idle_s : 0.0
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

"Shards that failed, with their error text: the answer to \"which of my 10,000 jobs broke\"."
failures(root::AbstractString, sweep::AbstractString) =
    [(; r.key, error = r.value) for r in results(root, sweep) if r.status == "error"]

"""
    retry_failed!(root, sweep) -> Int

Drop the entries for shards that errored, so the next reconcile runs them again. Returns how many
were cleared. Successful shards are untouched, so a retry costs only the failures.

Errors are NOT retried automatically. A shard that threw will usually throw again, and silently
re-running thousands of them wastes an allocation on a deterministic bug.
"""
function retry_failed!(root::AbstractString, sweep::AbstractString)
    n = 0
    for c in sweep_chunks(root, sweep), k in chunk_shards(root, c)
        m = MemoStore.read_manifest(root, k)
        m === nothing && continue
        String(get(m, "status", "")) == "error" || continue
        MemoStore.drop_manifest(root, k) && (n += 1)
    end
    return n
end

"""
    clear_attempts!(root, sweep) -> Int

Forget the submission history for a sweep, releasing chunks parked at the retry budget. Use after
fixing whatever was killing them (a longer walltime, more memory). Returns how many submission
records were dropped.
"""
function clear_attempts!(root::AbstractString, sweep::AbstractString)
    want = Set(sweep_chunks(root, sweep))
    n = 0
    for (name, cs) in known_submissions(root)
        any(in(want), cs) || continue
        rm(index_path(root, name); force = true); n += 1
    end
    a = read_attempts(root)
    cleared = [c for c in keys(a) if c in want]
    if !isempty(cleared)
        for c in cleared; delete!(a, c); end
        dir = jobs_dir(root); mkpath(dir); tmp = tempname(dir)
        try
            open(io -> TOML.print(io, Dict{String,Any}(k => v for (k, v) in a)), tmp, "w")
            mv(tmp, attempts_path(root); force = true)
        catch
            try; rm(tmp; force = true); catch; end
        end
        n = max(n, length(cleared))
    end
    return n
end

end # module BatchSweep
