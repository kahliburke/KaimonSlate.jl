# The notebook-facing surface of the batch fabric: `paramgrid`, `@sweep`, and `ShardedResult`.
#
# This half runs on the HUB only. `slatetask.jl` is what ships to a compute node and stays
# stdlib-only; nothing here needs to be loadable there.
#
# Why a macro and not `slate_map(f, grid)`: a batch task is a fresh process that cannot revive a
# serialized closure, so the body has to travel as SOURCE. A function value cannot hand back its own
# source, so the capture has to happen at parse time.

if !isdefined(@__MODULE__, :BatchSweep)
    Base.include(@__MODULE__, joinpath(@__DIR__, "batchsweep.jl"))
end

module Sweep

import SHA
import Serialization

const P = parentmodule(@__MODULE__)
const MemoStore = P.MemoStore
const SlateTask = P.SlateTask
const BatchLauncher = P.BatchLauncher
const BatchSweep = P.BatchSweep

export paramgrid, @sweep, SweepTarget, LocalTarget, SlurmTarget,
       finished, failures, values_of, refresh!, retry_failed!, reset!,
       sweep_state, fraction, eta, stalled_for, blocked

# ── Parameter space ──────────────────────────────────────────────────────────────────────────

"""
    paramgrid(; kw...) -> Vector{NamedTuple}

The cartesian product of the named axes, in column-major order (first axis varies fastest).

    paramgrid(β = 0.1:0.1:2.0, seed = 1:100)     # 2000 points

Adding a point later changes only that point's key, so the shards you already have are untouched.
"""
function paramgrid(; kw...)
    ks = collect(keys(kw))
    isempty(ks) && return NamedTuple[]
    vs = [collect(v) for v in values(kw)]
    out = NamedTuple[]
    for combo in Iterators.product(vs...)
        push!(out, NamedTuple{Tuple(ks)}(combo))
    end
    return out
end

"A grid from explicit rows, for a parameter set that is not a product."
paramgrid(rows::AbstractVector) = collect(rows)

# ── Targets ──────────────────────────────────────────────────────────────────────────────────
# A target says WHERE shards run and HOW the two sides see the store. Everything a notebook needs
# to switch between a laptop and a cluster lives here, so the sweep cell itself never changes.

abstract type SweepTarget end

"""
    LocalTarget(; root, chunk = 8, procs = …)

Run shards as local subprocesses. The default when there is no cluster, and the same cells work
against it.
"""
struct LocalTarget <: SweepTarget
    root::String
    project::String
    payload::String
    chunk::Int
end
function LocalTarget(; root = joinpath(homedir(), ".cache", "kaimonslate", "sweeps"),
                     project = dirname(Base.active_project()),
                     payload = joinpath(@__DIR__, "slatetask.jl"), chunk = 8)
    LocalTarget(String(root), String(project), String(payload), Int(chunk))
end

"""
    SlurmTarget(host; root, root_remote, project, payload, resources, chunk)

Submit shards to SLURM through `host` (a login node in `~/.ssh/config`; `""` runs the client tools
locally, which is the case when Slate itself runs on a login node).

`root` is the store as the HUB sees it and `root_remote` as a COMPUTE NODE sees it. They are the
same store; on a real cluster they are the same path, and they differ only when something is
mounted differently on the two sides.
"""
struct SlurmTarget <: SweepTarget
    host::String
    root::String
    root_remote::String
    project::String
    payload::String
    resources::NamedTuple
    chunk::Int
    account::String
    qos::String
    prologue::String
end
function SlurmTarget(host = ""; root, root_remote = root, project, payload,
                     resources = (; cpus = 1, mem = "2G", walltime = "01:00:00", partition = ""),
                     chunk = 16, account = "", qos = "", prologue = "")
    SlurmTarget(String(host), String(root), String(root_remote), String(project), String(payload),
                resources, Int(chunk), String(account), String(qos), String(prologue))
end

store_root(t::LocalTarget) = t.root
store_root(t::SlurmTarget) = t.root
chunk_size(t::LocalTarget) = t.chunk
chunk_size(t::SlurmTarget) = t.chunk

launcher_for(::LocalTarget) = BatchLauncher.ExecLauncher()
launcher_for(t::SlurmTarget) = BatchLauncher.SlurmLauncher(t.host; account = t.account, qos = t.qos)

specfn_for(t::LocalTarget) = (name, cs) -> BatchLauncher.JobSpec(name, cs;
    root = t.root, project = t.project, payload = t.payload)
specfn_for(t::SlurmTarget) = (name, cs) -> BatchLauncher.JobSpec(name, cs;
    root = t.root_remote, project = t.project, payload = t.payload,
    resources = t.resources, prologue = t.prologue)

# ── Keys ─────────────────────────────────────────────────────────────────────────────────────
# Everything is content-derived, which is what gives the sweep its useful properties: editing the
# body makes a NEW sweep rather than silently mixing results from two versions of the code, editing
# a downstream cell changes nothing, and adding parameters adds only those shards.

_hex(s) = bytes2hex(SHA.sha256(s))
_digest_value(v) = _hex(Serialization.serialize(IOBuffer(), v) === nothing ?
                        take!(let io = IOBuffer(); Serialization.serialize(io, v); io end) : UInt8[])

function _digest_of(v)
    io = IOBuffer(); Serialization.serialize(io, v); return _hex(take!(io))
end

function sweep_key(body_src, setup_src, captures)
    caps = join(sort(["$k=$(_digest_of(v))" for (k, v) in captures]), ";")
    return "sw" * first(_hex(string(body_src, "\0", setup_src, "\0", caps)), 16)
end

shard_key(sweep, param) = string(sweep, "_s", first(_digest_of(param), 12))
chunk_key(sweep, i) = string(sweep, "_c", i)

# ── Result ───────────────────────────────────────────────────────────────────────────────────

"""
    ShardedResult

A sweep's results, usable while incomplete. Indexable and iterable over rows of
`(; params, status, value, ran_on, ms)`, where `status` is `"ok"`, `"error"`, or `""` for a shard
that has not run.
"""
mutable struct ShardedResult
    key::String
    target::SweepTarget
    params::Vector{Any}
    keys::Vector{String}
    plan::BatchSweep.Plan
    rows::Vector{NamedTuple}
    telemetry::BatchSweep.Telemetry
end

Base.length(r::ShardedResult) = length(r.rows)
Base.getindex(r::ShardedResult, i) = r.rows[i]
Base.iterate(r::ShardedResult, s = 1) = s > length(r.rows) ? nothing : (r.rows[s], s + 1)
Base.eltype(::Type{ShardedResult}) = NamedTuple

# `sweep_state`, not `state`: this is exported into a notebook's namespace, where a bare `state`
# is far too likely to collide with the author's own variable.
sweep_state(r::ShardedResult) = r.plan.state
fraction(r::ShardedResult) = BatchSweep.fraction(r.plan)

"Seconds until the sweep finishes at the observed rate, or -1 when nothing has finished yet."
eta(r::ShardedResult) = r.telemetry.eta_s

"How long the sweep has looked stopped, or 0.0 if it looks healthy."
stalled_for(r::ShardedResult) = BatchSweep.stalled_for(r.telemetry)

"Why nothing more will be submitted (\"\" = not blocked)."
blocked(r::ShardedResult) = r.plan.blocked

"Rows whose shard completed successfully."
finished(r::ShardedResult) = [row for row in r.rows if row.status == "ok"]

"Just the return values of the successful shards, in grid order."
values_of(r::ShardedResult) = [row.value for row in r.rows if row.status == "ok"]

"Rows whose shard threw, with the traceback. The answer to \"which of them broke\"."
failures(r::ShardedResult) = [row for row in r.rows if row.status == "error"]

function _rows(root, params, keys)
    rows = NamedTuple[]
    for (prm, k) in zip(params, keys)
        m = MemoStore.read_manifest(root, k)
        if m === nothing
            push!(rows, (; params = prm, status = "", value = nothing, ran_on = "", ms = 0.0))
            continue
        end
        _, st, v = SlateTask.result(root, k)
        push!(rows, (; params = prm, status = st, value = v,
                     ran_on = String(get(m, "ran_on", "")), ms = Float64(get(m, "ms", 0.0))))
    end
    return rows
end

"""
    refresh!(r) -> r

Re-read the store and the scheduler. This is what a sweep cell does when it is re-run, and what a
progress display calls on a timer.
"""
function refresh!(r::ShardedResult)
    root = store_root(r.target)
    l = launcher_for(r.target)
    r.plan = BatchSweep.plan(root, r.key; launcher = l)
    r.rows = _rows(root, r.params, r.keys)
    r.telemetry = BatchSweep.telemetry(root, r.key; launcher = l, plan = r.plan)
    return r
end

"Clear the failed shards so the next run of the sweep cell retries exactly those."
retry_failed!(r::ShardedResult) = BatchSweep.retry_failed!(store_root(r.target), r.key)

"Drop every result for this sweep, so the next run starts cold."
function reset!(r::ShardedResult)
    root = store_root(r.target)
    n = 0
    for k in r.keys; MemoStore.drop_manifest(root, k) && (n += 1); end
    BatchSweep.clear_attempts!(root, r.key)
    return n
end

# Duration as something a person reads at a glance. "4302 seconds elapsed" is exactly the
# unhelpful form this exists to avoid.
function _dur(s::Real)
    s < 0 && return "?"
    s < 1   && return "<1s"
    s < 60  && return string(round(Int, s), "s")
    s < 3600 && return string(round(Int, s ÷ 60), "m", lpad(round(Int, s % 60), 2, '0'), "s")
    s < 86400 && return string(round(Int, s ÷ 3600), "h", lpad(round(Int, (s % 3600) ÷ 60), 2, '0'), "m")
    return string(round(s / 86400; digits = 1), "d")
end

_bar(frac, width = 24) =
    (n = clamp(round(Int, frac * width), 0, width); "▰"^n * "▱"^(width - n))

function Base.show(io::IO, ::MIME"text/plain", r::ShardedResult)
    p = r.plan
    t = r.telemetry
    icon = p.state === :succeeded ? "✅" : p.state === :partial ? "⚠️" :
           p.state === :stalled   ? "⛔" : p.state === :blocked ? "🛑" :
           p.state === :running   ? "⏳" : "•"
    pct = round(100 * BatchSweep.fraction(p); digits = 1)
    println(io, "$icon sweep $(r.key) — $(p.state)")
    println(io, "   $(_bar(BatchSweep.fraction(p)))  $(p.shards_done)/$(p.shards_total) ($pct%)")
    println(io, "   ok $(p.shards_ok)   errored $(p.shards_failed)   remaining $(p.shards_missing)")

    # The three numbers a long run is actually asking about. Suppressed once nothing more will
    # happen: "<1s remaining" on a finished sweep is noise, and an ETA on a blocked or stalled one
    # is a promise it will not keep.
    if t.done > 0 && !BatchSweep.is_settled(p) && !BatchSweep.is_stuck(p)
        parts = String[]
        t.rate_per_s > 0 && push!(parts, string(round(t.rate_per_s; digits = 2), " units/s"))
        t.eta_s >= 0     && push!(parts, "~$(_dur(t.eta_s)) remaining")
        t.mean_unit_s > 0 && push!(parts, "$(_dur(t.mean_unit_s))/unit")
        isempty(parts) || println(io, "   ", join(parts, " · "))
    end

    hosts = unique([row.ran_on for row in r.rows if !isempty(row.ran_on)])
    isempty(hosts) || println(io, "   ran on: ", join(first(hosts, 6), ", "),
                              length(hosts) > 6 ? " (+$(length(hosts) - 6) more)" : "")

    idle = BatchSweep.stalled_for(t)
    idle > 0 && println(io, "   ⚠ nothing has finished in $(_dur(idle)) — it may be stuck.")

    if p.state === :blocked
        println(io, "   🛑 $(p.blocked)")
        println(io, "   Nothing further will be submitted. Fix the body, then `reset!(r)`.")
    elseif p.state === :partial
        println(io, "   `failures(r)` lists the errors; `retry_failed!(r)` clears them for a retry.")
    elseif p.state === :stalled
        println(io, "   attempted $(BatchSweep.MAX_ATTEMPTS)× without landing. Raise the walltime or",
                    " memory, then `reset!(r)`.")
    elseif p.state !== :succeeded
        println(io, "   re-run this cell to refresh.")
    end
end

# ── The sweep itself ─────────────────────────────────────────────────────────────────────────

"""
    run_sweep(target, params, body_src; setup_src = "", captures = Dict(), submit = true) -> ShardedResult

The function `@sweep` expands to. Idempotent: it works out what is missing, submits exactly that,
and returns immediately with whatever has already landed.
"""
function run_sweep(target::SweepTarget, params::AbstractVector, body_src::AbstractString;
                   setup_src::AbstractString = "", captures::AbstractDict = Dict{Symbol,Any}(),
                   submit::Bool = true, cap::Integer = 0)
    root = store_root(target)
    mkpath(root)
    key = sweep_key(body_src, setup_src, captures)
    keys = [shard_key(key, prm) for prm in params]

    # (Re)write the descriptors. Content-addressed, so doing this every run is nearly free: the
    # blobs already exist and only ~1 KB of manifests is rewritten.
    per = max(1, chunk_size(target))
    chunks = String[]
    for (ci, lo) in enumerate(1:per:length(params))
        hi = min(lo + per - 1, length(params))
        ck = chunk_key(key, ci)
        SlateTask.write_chunk!(root, ck; fn_src = body_src, setup_src = setup_src,
                               captures = Dict(String(k) => v for (k, v) in captures),
                               params = params[lo:hi], keys = keys[lo:hi])
        push!(chunks, ck)
    end
    BatchSweep.write_sweep!(root, key, chunks)

    launcher = launcher_for(target)
    if submit
        BatchSweep.reconcile!(root, key, launcher, specfn_for(target); cap)
    end
    pl = BatchSweep.plan(root, key; launcher)
    tl = BatchSweep.telemetry(root, key; launcher, plan = pl)
    return ShardedResult(key, target, collect(params), keys, pl, _rows(root, params, keys), tl)
end

# Free names in the body that are bound in the calling module and look like DATA. These travel with
# the sweep as serialized captures.
#
# Functions, modules, and types are deliberately excluded: a compute node cannot revive a function
# value, only source. Helpers therefore belong in `setup=`, which travels as text.
function _capture_names(body, param::Symbol)
    found = Set{Symbol}()
    walk(x) = nothing
    walk(s::Symbol) = (push!(found, s); nothing)
    function walk(e::Expr)
        # Skip the field name in `a.b` and keyword names in `f(; k = v)`.
        if e.head === :. && length(e.args) == 2
            walk(e.args[1]); return nothing
        end
        for a in e.args; walk(a); end
        return nothing
    end
    walk(body)
    delete!(found, param)
    return found
end

function _collect_captures(mod::Module, names, param::Symbol)
    caps = Dict{Symbol,Any}()
    for n in names
        n === param && continue
        isdefined(mod, n) || continue
        v = try; getfield(mod, n); catch; continue; end
        (v isa Function || v isa Module || v isa Type) && continue
        caps[n] = v
    end
    return caps
end

"""
    @sweep grid target [setup=…] [chunk=…] do p
        …
    end

Run the body once per row of `grid`, as batch work on `target`, and return a [`ShardedResult`].

The body travels as SOURCE, so it must be self-contained apart from:

  * plain data from the notebook, which is captured and serialized automatically, and
  * helper definitions, which go in `setup=` (a string) because a function value cannot be revived
    on a compute node.

Re-running the cell is a reconcile: whatever has landed is kept, only what is missing is submitted.
Editing the body makes it a different sweep.
"""
macro sweep(args...)
    # A do-block is passed as the FIRST argument, so find the lambda rather than assuming where it
    # sits; that also keeps `@sweep(grid, target, setup = s) do p … end` working.
    bi = findfirst(a -> a isa Expr && a.head === :(->), args)
    bi === nothing &&
        error("@sweep expects a do-block: `@sweep(grid, target) do p … end`")
    body = args[bi]
    rest = [a for (i, a) in enumerate(args) if i != bi]
    length(rest) >= 2 || error("@sweep needs a grid and a target: `@sweep(grid, target) do p … end`")
    grid, target = rest[1], rest[2]

    opts = Dict{Symbol,Any}()
    for a in rest[3:end]
        (a isa Expr && a.head === :(=)) || error("@sweep: unexpected argument $(a)")
        opts[a.args[1]] = a.args[2]
    end

    # The do-block's parameter and body, as written.
    plist = body.args[1]
    param = plist isa Symbol ? plist :
            (plist isa Expr && plist.head === :tuple && length(plist.args) == 1) ? plist.args[1] :
            error("@sweep's do-block takes exactly one parameter")
    inner = body.args[2]

    body_src = string(param, " -> begin\n", string(inner), "\nend")
    names = _capture_names(inner, param)
    setup = get(opts, :setup, "")
    cap   = get(opts, :cap, 0)

    quote
        local _names = $(QuoteNode(collect(names)))
        local _caps = $(Sweep)._collect_captures(@__MODULE__, _names, $(QuoteNode(param)))
        $(Sweep).run_sweep($(esc(target)), collect($(esc(grid))), $body_src;
                           setup_src = $(esc(setup)), captures = _caps, cap = $(esc(cap)))
    end
end

end # module Sweep
