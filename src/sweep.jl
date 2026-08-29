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
import Pkg

# The env-preparation policy shared by the notebook fork and the remote provisioner. envprep.jl is
# pure TOML/file operations with no transport of its own, precisely so a new transport can reuse it:
# batch is the third, after the local filesystem fork and ssh/rsync.
Base.include(@__MODULE__, joinpath(@__DIR__, "envprep.jl"))

const P = parentmodule(@__MODULE__)
const MemoStore = P.MemoStore
const SlateTask = P.SlateTask
const BatchLauncher = P.BatchLauncher
const BatchSweep = P.BatchSweep

export paramgrid, @sweep, SweepTarget, LocalTarget, SlurmTarget,
       finished, failures, values_of, refresh!, retry_failed!, reset!,
       cancel!, resume!, sweep_state, fraction, eta, stalled_for, blocked

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

# ── The environment task processes run in ────────────────────────────────────────────────────
# Seeded from the notebook's PARENT project by the same policy the notebook fork and the remote
# provisioner use, then instantiated once. Keyed by the parent's fingerprint, so repeated sweeps
# against an unchanged parent cost nothing.
#
# What belongs in it depends on what the body sweeps:
#
#   * a call into parent-module code (`MyPkg.simulate(p)`) needs the parent and nothing else;
#   * notebook code that uses a package the NOTEBOOK added needs that package too.
#
# The notebook's own additions are deliberately not replayed wholesale. They are usually plotting
# and display packages that only the hub needs, and every one of them is startup time and memory on
# every task process. Name what the body actually needs instead.
#
#   env = :parent              seed from the parent project (default)
#   env = ["DataFrames"]       the parent, plus these packages
#   env = "/path/to/env"       an environment you manage yourself
#
# Precompilation happens HERE, once. Task processes run with JULIA_PKG_PRECOMPILE_AUTO=0 so that
# hundreds of them cannot each decide to precompile into the same depot at once.
function task_env!(root::AbstractString, parent::AbstractString, env)
    env isa AbstractString && return String(env)          # caller manages it
    isempty(parent) && return ""                          # detached notebook: nothing to seed from

    extras = env isa AbstractVector ? String.(env) : String[]
    key = first(string(hash((env_parent_fingerprint(parent), extras)); base = 16), 12)
    envdir = joinpath(root, "taskenv", key)

    if !env_stale(envdir, parent) && isfile(joinpath(envdir, "Manifest.toml"))
        return envdir
    end

    pname = seed_env_project!(envdir, parent)
    add = isempty(extras) ? "" :
          "Pkg.add([" * join(("\"$e\"" for e in extras), ", ") * "]);"
    dev = isempty(pname) ? "" : "Pkg.develop(Pkg.PackageSpec(path=raw\"$(parent)\"));"
    # A subprocess: `Pkg.instantiate`/`precompile` inside a live worker is not safe.
    code = "using Pkg; Pkg.activate(raw\"$(envdir)\"); $dev $add Pkg.instantiate(); Pkg.precompile()"
    ok = try
        run(pipeline(`$(Base.julia_cmd()) --startup-file=no -e $code`;
                     stdout = devnull, stderr = devnull))
        true
    catch
        false
    end
    ok || error("could not prepare the task environment at $envdir from parent $parent")
    stamp_env!(envdir, parent)
    return envdir
end

# ── Remote provisioning ──────────────────────────────────────────────────────────────────────
# The same idea as `task_env!`, over ssh instead of the local filesystem: get the parent project
# onto the cluster and instantiate an environment from it, once.
#
# Precompilation happens HERE and only here. Task jobs run with JULIA_PKG_PRECOMPILE_AUTO=0, so a
# few hundred array elements starting at once cannot each decide to precompile into the same depot
# — which is how a shared filesystem gets taken down.

function _ssh_run(host, script; capture::Bool = false)
    cmd = isempty(host) ? `sh -c $script` :
          `ssh -o BatchMode=yes -o ConnectTimeout=15 $host $script`
    buf = IOBuffer()
    ok = try; run(pipeline(cmd; stdout = buf, stderr = buf)); true; catch; false; end
    return (ok, String(take!(buf)))
end

"""
    provision_remote_env!(host, root_remote, parent; julia = "julia", prologue = "") -> envdir

Ship `parent` to the cluster and instantiate a task environment from it. Idempotent: keyed by the
parent's fingerprint, so an unchanged parent costs one `test -f` over ssh.

Returns the environment path as a COMPUTE NODE sees it.
"""
function provision_remote_env!(host::AbstractString, root_remote::AbstractString,
                               parent::AbstractString; julia::AbstractString = "julia",
                               prologue::AbstractString = "")
    isempty(parent) && return joinpath(root_remote, "env")
    fp = env_parent_fingerprint(parent)
    key = first(fp, 12)
    envdir = "$(root_remote)/env/$(key)"
    stamp = "$(envdir)/.slate-parent"

    ok, _ = _ssh_run(host, "test -f $(stamp) && grep -qx '$(fp)' $(stamp)")
    ok && return envdir                              # already provisioned for this parent

    pname = try
        pt = Pkg.TOML.parsefile(joinpath(parent, "Project.toml"))
        (haskey(pt, "name") && haskey(pt, "uuid")) ? String(pt["name"]) : ""
    catch
        ""
    end
    remote_pkg = "$(root_remote)/pkg/$(basename(rstrip(parent, '/')))"

    ok, out = _ssh_run(host, "mkdir -p $(remote_pkg) $(envdir)")
    ok || error("could not create $(remote_pkg) on $(host): $(strip(out))")

    # rsync the project itself. `--delete` so a removed source file does not linger and get loaded.
    dest = isempty(host) ? remote_pkg : "$(host):$(remote_pkg)"
    try
        run(pipeline(`rsync -az --delete --exclude .git --exclude Manifest.toml
                      $(rstrip(parent, '/'))/ $(dest)/`; stdout = devnull, stderr = devnull))
    catch e
        error("could not copy $(parent) to $(host):$(remote_pkg) ($(sprint(showerror, e)))")
    end

    pre = isempty(prologue) ? "" : prologue * "\n"
    dev = isempty(pname) ? "" : "Pkg.develop(Pkg.PackageSpec(path=raw\"$(remote_pkg)\"));"
    code = "using Pkg; Pkg.activate(raw\"$(envdir)\"); $dev Pkg.instantiate(); Pkg.precompile()"
    ok, out = _ssh_run(host, "$(pre)$(julia) --startup-file=no -e '$(code)' && " *
                             "printf '%s' '$(fp)' > $(stamp)")
    ok || error("could not instantiate the task environment on $(host):\n$(strip(out))")
    return envdir
end

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
#
# The task environment is PREPARED here, at construction: seeded from `parent` and instantiated once
# (see `task_env!`). That is a visible, one-time cost in the cell that defines the target, rather
# than a surprise on the first submission.
#
# `parent` defaults to the notebook's own parent project, which is what holds the code a sweep body
# usually calls into. Pass `env = ["Pkg1", …]` for packages the body needs beyond it, or
# `env = "/path"` to manage the environment yourself.
function LocalTarget(; root = joinpath(homedir(), ".cache", "kaimonslate", "sweeps"),
                     parent = dirname(Base.active_project()), env = :parent,
                     project = nothing,
                     payload = joinpath(@__DIR__, "slatetask.jl"), chunk = 8)
    mkpath(String(root))
    proj = project === nothing ? task_env!(String(root), String(parent), env) : String(project)
    LocalTarget(String(root), proj, String(payload), Int(chunk))
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
#
# `parent` provisions the task environment on the cluster (see `provision_remote_env!`) and is the
# normal way to use this. Pass `project` instead to point at an environment the site already
# manages, in which case nothing is shipped.
function SlurmTarget(host = ""; root, root_remote = root, payload,
                     parent = "", project = nothing,
                     resources = (; cpus = 1, mem = "2G", walltime = "01:00:00", partition = ""),
                     chunk = 16, account = "", qos = "", prologue = "", julia = "julia")
    proj = project !== nothing ? String(project) :
           provision_remote_env!(String(host), String(root_remote), String(parent);
                                 julia = String(julia), prologue = String(prologue))
    SlurmTarget(String(host), String(root), String(root_remote), proj, String(payload),
                resources, Int(chunk), String(account), String(qos), String(prologue))
end

# Resources belong to the TARGET (a site's account, its partitions) but walltime, memory and cores
# are properties of the WORK, and vary sweep to sweep against the same cluster. So a sweep can
# override them without defining a second target.
with_resources(t::LocalTarget, res) = t          # nothing to schedule locally
with_resources(t::SlurmTarget, res) =
    res === nothing ? t :
    SlurmTarget(t.host, t.root, t.root_remote, t.project, t.payload,
                merge(t.resources, res), t.chunk, t.account, t.qos, t.prologue)

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

# Drop LineNumberNodes so a body's text depends only on the code, not on where it sits in a file.
_strip_lines(x) = x
function _strip_lines(e::Expr)
    args = Any[_strip_lines(a) for a in e.args if !(a isa LineNumberNode)]
    return Expr(e.head, args...)
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

"""
    cancel!(r) -> r

Stop the sweep at your request: kill what is running and record the stop durably, so re-running the
cell (or reopening the notebook) does not quietly start it again. Finished units are kept.
"""
function cancel!(r::ShardedResult)
    BatchSweep.cancel!(store_root(r.target), r.key, launcher_for(r.target))
    return refresh!(r)
end

"""
    resume!(r) -> r

Undo a `cancel!`. The next run submits only what is still missing.
"""
function resume!(r::ShardedResult)
    BatchSweep.resume!(store_root(r.target), r.key)
    return refresh!(r)
end

"Drop every result for this sweep, so the next run starts cold."
function reset!(r::ShardedResult)
    root = store_root(r.target)
    n = 0
    for k in r.keys; MemoStore.drop_manifest(root, k) && (n += 1); end
    BatchSweep.clear_attempts!(root, r.key)
    BatchSweep.resume!(root, r.key)   # a reset sweep is not still cancelled
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

# ── Live status over the JS channel ──────────────────────────────────────────────────────────
# A monitor that re-ran the cell to advance would re-run every downstream cell with it, which for a
# sweep of thousands of units is far more work than the sweep. Instead the rendered card polls a
# `slateCall` channel and patches its own DOM: the browser animates, and the notebook's dependency
# graph is untouched until the VALUE actually changes.
#
# The handler re-reads the store on every call rather than closing over a snapshot, so it stays
# correct across a worker restart and reports what is actually on disk.

"The channel a sweep's card polls. One per sweep, so two sweeps in a notebook do not collide."
status_channel(key::AbstractString) = "sweep:" * String(key)

"The channel the card's buttons call. Separate from status so a poll can never be a mutation."
action_channel(key::AbstractString) = "sweep:" * String(key) * ":do"

"""
    handle_action(target, key, params, keys, action) -> payload

Apply a control the card offers, then report the resulting state so the button press and the
refresh are one round trip.

`cancel` and `reset` are destructive in different degrees and are kept apart deliberately: cancel
STOPS a sweep and keeps every finished unit, so resuming costs only what is left; reset throws the
results away.
"""
function handle_action(target::SweepTarget, key::AbstractString, params, keys,
                       action::AbstractString)
    root = store_root(target)
    l = launcher_for(target)
    if action == "cancel"
        BatchSweep.cancel!(root, key, l)
    elseif action == "resume"
        BatchSweep.resume!(root, key)
    elseif action == "retry"
        BatchSweep.retry_failed!(root, key)
    elseif action == "reset"
        BatchSweep.resume!(root, key)
        for k in keys; MemoStore.drop_manifest(root, k); end
        BatchSweep.clear_attempts!(root, key)
    else
        error("unknown sweep action: $(action)")
    end
    # A cancel must not be undone by the reconcile its own refresh would trigger.
    return status_payload(target, key, params, keys; advance = (action != "cancel"))
end

# Compact enough to poll on a timer: counts and rates, plus a per-unit status string of one
# character each. At a few thousand units that string is a few KB, which is cheap next to sending
# structured rows for every unit.
function status_payload(target::SweepTarget, key::AbstractString, params, keys;
                        advance::Bool = true)
    root = store_root(target)
    l = launcher_for(target)
    # The poll RECONCILES, it does not merely observe. The probe wave releases one chunk and waits
    # for it to report; if only the cell could reconcile, a sweep would sit at "10 / 60, running"
    # until the author re-ran it by hand, once per wave. Reconciling is idempotent and submits
    # nothing that is already live, so polling it is safe — and the breaker still stops a sweep
    # whose units are failing, which is the case the waves exist for.
    p = advance ? BatchSweep.reconcile!(root, key, l, specfn_for(target)) :
                  BatchSweep.plan(root, key; launcher = l)
    t = BatchSweep.telemetry(root, key; launcher = l, plan = p)
    # Tile COLOURS, not per-unit statuses: the browser patches tiles by index, and computing the
    # colour here is what keeps the live grid identical to the one the cell rendered. It also keeps
    # the payload flat — a few hundred short strings whatever the sweep's size.
    st = [(m = MemoStore.read_manifest(root, k);
           m === nothing ? "" : String(get(m, "status", ""))) for k in keys]
    tiles = String[]
    for (lo, hi) in _tile_spans(length(st))
        ok = count(==("ok"), @view st[lo:hi])
        err = count(==("error"), @view st[lo:hi])
        push!(tiles, _tile_color(ok, err, hi - lo + 1))
    end

    return Dict{String,Any}(
        "state" => String(p.state), "label" => _state_label(p.state),
        "total" => p.shards_total, "done" => p.shards_done,
        "ok" => p.shards_ok, "failed" => p.shards_failed, "missing" => p.shards_missing,
        "frac" => BatchSweep.fraction(p),
        "rate" => t.rate_per_s, "eta" => t.eta_s, "idle" => t.idle_s,
        "stuck" => BatchSweep.stalled_for(t), "blocked" => p.blocked,
        "settled" => BatchSweep.is_settled(p), "tiles" => tiles,
        "color" => get(_STATE_COLOR, p.state, "#8b949e"))
end

# ── HTML rendering ───────────────────────────────────────────────────────────────────────────
# The notebook's view of a sweep. The text form below stays as the fallback for a standalone
# `julia notebook.jl` run, the REPL, and static export, where there is no DOM to write into.
#
# Styles are inline and theme variables carry fallbacks, so this renders correctly in an exported
# page that never loaded the notebook's stylesheet.

_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

const _STATE_COLOR = Dict(
    :succeeded => "#3fb950", :partial   => "#d29922", :blocked => "#f85149",
    :exhausted => "#f85149", :cancelled => "#8b949e", :running => "#58a6ff",
    :pending   => "#8b949e")

# The three ways of stopping short read differently on purpose: one is the work's fault, one is
# yours, and one is the resources'.
_state_label(s) = s === :succeeded ? "complete" :
                  s === :partial   ? "finished, with failures" :
                  s === :blocked   ? "stopped — the work is failing" :
                  s === :cancelled ? "stopped at your request" :
                  s === :exhausted ? "gave up — units never landed" :
                  s === :running   ? "running" : "not started"

# The unit grid, BINNED to a fixed tile budget. One tile per unit does not survive contact with a
# real sweep: a hundred thousand units would be a hundred thousand DOM nodes, rebuilt on every
# refresh, exactly when the sweep is large enough to matter.
#
# So a tile covers `ceil(n / budget)` consecutive units and is coloured by what is IN it. The
# spatial story survives binning — failures clustered in one region of the parameter space still
# show as a red band — while the DOM cost stays flat from ten units to ten million.
const _TILE_BUDGET = 600

# The one definition of how units map onto tiles. The renderer and the live payload MUST agree: the
# browser patches tiles by index, so if the two binned differently the grid would either stop
# updating or repaint the wrong cells — and only on large sweeps, which are the ones worth watching.
function _tile_spans(n::Integer)
    n <= 0 && return Tuple{Int,Int}[]
    per = max(1, cld(n, _TILE_BUDGET))
    return [((t - 1) * per + 1, min(t * per, n)) for t in 1:cld(n, per)]
end

# Green for completed, blended toward red by the bucket's failure fraction, so a region that is
# merely slow and a region that is failing do not look alike. Grey is "nothing here has run".
function _tile_color(ok::Int, err::Int, total::Int)
    done = ok + err
    done == 0 && return "#30363d"
    f = err / done                                   # failure share of what has finished
    base = done / total                              # how much of the bucket has landed
    r = round(Int, 63 + f * (248 - 63))
    g = round(Int, 185 - f * (185 - 81))
    b = round(Int, 80 - f * (80 - 73))
    a = round(0.35 + 0.65 * base; digits = 2)        # unfinished buckets sit dimmer
    return "rgba($r,$g,$b,$a)"
end

function _unit_grid(io, r::ShardedResult)
    n = length(r.rows)
    n == 0 && return
    spans = _tile_spans(n)
    per = n == 0 ? 1 : max(1, cld(n, _TILE_BUDGET))
    side = length(spans) <= 100 ? 12 : length(spans) <= 400 ? 8 : 5

    print(io, "<div data-sw='grid' style='display:flex;flex-wrap:wrap;gap:2px;margin-top:8px'>")
    for (lo, hi) in spans
        ok = err = 0
        for i in lo:hi
            s = r.rows[i].status
            s == "ok" ? (ok += 1) : s == "error" ? (err += 1) : nothing
        end
        tip = if per == 1
            row = r.rows[lo]
            _esc(string(row.params)) *
                (isempty(row.ran_on) ? "" : " · " * _esc(row.ran_on)) *
                (row.status == "" ? " · not run" : " · " * row.status)
        else
            "units $(lo)-$(hi) · $(ok) ok, $(err) failed, $(hi - lo + 1 - ok - err) pending"
        end
        print(io, "<div title=\"", tip, "\" style='width:", side, "px;height:", side,
                  "px;border-radius:2px;background:", _tile_color(ok, err, hi - lo + 1), "'></div>")
    end
    println(io, "</div>")
    per > 1 && println(io, "<div style='font-size:10px;opacity:.45;margin-top:3px'>",
                           "each tile ≈ ", per, " units</div>")
end

function Base.show(io::IO, ::MIME"text/html", r::ShardedResult)
    p, t = r.plan, r.telemetry
    frac = BatchSweep.fraction(p)
    col = get(_STATE_COLOR, p.state, "#8b949e")

    # `data-sw` hooks mark every part the live script patches; without them it would have to
    # rebuild the card, and the parts that come from Julia (failures, the blocked reason) cannot be
    # rebuilt in the browser.
    print(io, "<div data-sweep='sw-", first(r.key, 12), "' ",
              "style='font-family:var(--font-ui,system-ui);color:var(--fg,#c9d1d9);",
              "border:1px solid var(--border,#30363d);border-radius:8px;padding:12px 14px;",
              "background:var(--bg-elev,#0d1117)'>")

    # Header: what state it is in, and how far.
    print(io, "<div style='display:flex;align-items:center;gap:8px;margin-bottom:8px'>",
              "<span data-sw='dot' style='display:inline-block;width:8px;height:8px;",
              "border-radius:50%;background:", col, "'></span>",
              "<strong data-sw='label' style='color:", col, "'>", _state_label(p.state), "</strong>",
              "<span style='opacity:.5;font-size:12px'>", _esc(r.key), "</span>",
              "<span style='margin-left:auto;font-variant-numeric:tabular-nums'>",
              "<span data-sw='count'>", p.shards_done, " / ", p.shards_total, "</span> ",
              "<span data-sw='pct' style='opacity:.6'>(", round(100 * frac; digits = 1),
              "%)</span></span></div>")

    # Progress bar.
    print(io, "<div style='height:6px;border-radius:3px;background:var(--border,#30363d);",
              "overflow:hidden'><div data-sw='bar' style='height:100%;width:",
              round(100 * frac; digits = 2), "%;background:", col, ";transition:width .3s'></div></div>")

    # Counts.
    print(io, "<div style='display:flex;gap:14px;margin-top:8px;font-size:12px'>")
    print(io, "<span data-sw='ok' style='color:#3fb950'>", p.shards_ok, " ok</span>")
    print(io, "<span data-sw='failed' style='color:#f85149'>",
              p.shards_failed > 0 ? "$(p.shards_failed) failed" : "", "</span>")
    print(io, "<span data-sw='missing' style='opacity:.6'>",
              p.shards_missing > 0 ? "$(p.shards_missing) remaining" : "", "</span>")
    print(io, "<span data-sw='rate' style='margin-left:auto;opacity:.7'>",
              (t.done > 0 && !BatchSweep.is_settled(p) && !BatchSweep.is_stuck(p) &&
               t.rate_per_s > 0) ? "$(round(t.rate_per_s; digits = 2))/s" : "", "</span>")
    if t.done > 0 && !BatchSweep.is_settled(p) && !BatchSweep.is_stuck(p) && t.eta_s >= 0
        print(io, "<span style='opacity:.7'>~", _dur(t.eta_s), " left</span>")
    end
    println(io, "</div>")
    print(io, "<div data-sw='note' style='font-size:11px;opacity:.5;margin-top:4px'></div>")

    _unit_grid(io, r)

    hosts = unique([row.ran_on for row in r.rows if !isempty(row.ran_on)])
    isempty(hosts) || print(io, "<div style='font-size:11px;opacity:.5;margin-top:8px'>ran on ",
                                _esc(join(first(hosts, 8), ", ")),
                                length(hosts) > 8 ? " (+$(length(hosts) - 8))" : "", "</div>")

    idle = BatchSweep.stalled_for(t)
    idle > 0 && print(io, "<div style='margin-top:8px;font-size:12px;color:#d29922'>",
                          "⚠ nothing has finished in ", _dur(idle), " — it may be stuck.</div>")

    # Each stopped state says what to do next, because they need different things.
    if p.state === :blocked
        print(io, "<div style='margin-top:8px;padding:8px;border-radius:6px;",
                  "background:rgba(248,81,73,.12);font-size:12px;color:#f85149'>",
                  _esc(p.blocked), "<br><span style='opacity:.8'>Nothing further will be ",
                  "submitted. Fix the body, then <code>reset!</code>.</span></div>")
    elseif p.state === :cancelled
        print(io, "<div style='margin-top:8px;padding:8px;border-radius:6px;",
                  "background:rgba(139,148,158,.12);font-size:12px;opacity:.85'>",
                  "Stopped at your request. ", p.shards_done, " finished units are kept — ",
                  "<code>resume!</code> continues with the remaining ", p.shards_missing, ".</div>")
    elseif p.state === :exhausted
        print(io, "<div style='margin-top:8px;padding:8px;border-radius:6px;",
                  "background:rgba(248,81,73,.12);font-size:12px;color:#f85149'>",
                  "Attempted ", BatchSweep.MAX_ATTEMPTS, "× without landing, so these units are ",
                  "outrunning their resources rather than erroring.<br><span style='opacity:.8'>",
                  "Raise the walltime or memory, then <code>reset!</code>.</span></div>")
    end

    # Failures, collapsed. The parameters matter more than the traceback at a glance, so they lead.
    fails = failures(r)
    if !isempty(fails)
        print(io, "<details style='margin-top:8px'><summary style='cursor:pointer;font-size:12px;",
                  "color:#f85149'>", length(fails), " failed unit",
                  length(fails) == 1 ? "" : "s", "</summary>")
        print(io, "<div style='max-height:220px;overflow:auto;margin-top:6px'>")
        for f in first(fails, 50)
            print(io, "<div style='margin-bottom:6px;font-size:11px'>",
                      "<code style='color:#d29922'>", _esc(string(f.params)), "</code>",
                      "<pre style='margin:2px 0 0;white-space:pre-wrap;opacity:.75'>",
                      _esc(first(String(f.value), 400)), "</pre></div>")
        end
        length(fails) > 50 && print(io, "<div style='opacity:.6;font-size:11px'>… and ",
                                        length(fails) - 50, " more</div>")
        println(io, "</div></details>")
    end

    _actions(io, r)
    _live_script(io, r)
    println(io, "</div>")
    return nothing
end

# Only the controls that apply to the state it is in. A "Cancel" on a finished sweep or a "Resume"
# on one that was never stopped is a button that either does nothing or does something surprising.
function _actions(io, r::ShardedResult)
    p = r.plan
    acts = Tuple{String,String}[]
    if p.state === :running || p.state === :pending
        push!(acts, ("cancel", "Cancel"))
    elseif p.state === :cancelled
        push!(acts, ("resume", "Resume"))
    end
    p.shards_failed > 0 && push!(acts, ("retry", "Retry $(p.shards_failed) failed"))
    (p.state === :blocked || p.state === :exhausted || BatchSweep.is_settled(p)) &&
        push!(acts, ("reset", "Reset"))
    isempty(acts) && return

    print(io, "<div style='display:flex;gap:6px;margin-top:10px'>")
    for (act, label) in acts
        print(io, "<button data-sw-do='", act, "' style='font:inherit;font-size:11px;",
                  "padding:3px 9px;border-radius:5px;cursor:pointer;",
                  "border:1px solid var(--border,#30363d);background:transparent;",
                  "color:var(--fg,#c9d1d9)'>", _esc(label), "</button>")
    end
    println(io, "</div>")
end

# Poll the sweep's channel and patch the card in place. Only while there is something to wait for:
# a settled sweep renders static and starts no timer, so a notebook full of finished sweeps costs
# nothing. The interval backs off as a run gets long, because a sweep of hours does not need
# second-by-second updates and the poll is a round trip to the scheduler.
function _live_script(io, r::ShardedResult)
    ch = status_channel(r.key)
    doch = action_channel(r.key)
    # The buttons are wired whatever the state; only the POLL is conditional. A finished sweep still
    # offers Retry and Reset, and a card that started no timer must not be inert.
    poll = !(BatchSweep.is_settled(r.plan) || BatchSweep.is_stuck(r.plan))
    id = "sw-" * first(r.key, 12)
    print(io, """
    <script>
    (function(){
      var root = document.currentScript.closest('[data-sweep="$(id)"]') ||
                 document.currentScript.parentElement;
      if (!root || root.dataset.swLive === "1") return;
      root.dataset.swLive = "1";
      var started = Date.now(), timer = null;
      function interval(){
        var mins = (Date.now() - started) / 60000;
        return mins < 2 ? 2000 : mins < 15 ? 5000 : 15000;
      }
      function paint(s){
        // Feed the notebook-level pill. The card is inside one cell's output; the pill is what
        // answers "what is this notebook doing" when that cell is scrolled away or collapsed.
        if (window.slateSweeps) {
          var cell = root.closest('[data-cid]');
          window.slateSweeps.report("$(r.key)", cell ? cell.dataset.cid : "", s);
        }
        var bar = root.querySelector('[data-sw="bar"]');
        if (bar) bar.style.width = (100 * s.frac).toFixed(2) + "%";
        if (bar) bar.style.background = s.color;
        var set = function(k, v){
          var el = root.querySelector('[data-sw="' + k + '"]');
          if (el) el.textContent = v;
        };
        set("count", s.done + " / " + s.total);
        set("pct", "(" + (100 * s.frac).toFixed(1) + "%)");
        set("ok", s.ok + " ok");
        set("failed", s.failed > 0 ? s.failed + " failed" : "");
        set("missing", s.missing > 0 ? s.missing + " remaining" : "");
        set("rate", s.rate > 0 && !s.settled ? s.rate.toFixed(2) + "/s" : "");
        set("label", s.label);
        var lab = root.querySelector('[data-sw="label"]');
        if (lab) lab.style.color = s.color;
        var dot = root.querySelector('[data-sw="dot"]');
        if (dot) dot.style.background = s.color;
        var g = root.querySelector('[data-sw="grid"]');
        if (g && s.tiles && g.children.length === s.tiles.length){
          for (var i = 0; i < s.tiles.length; i++){
            if (g.children[i].style.background !== s.tiles[i])
              g.children[i].style.background = s.tiles[i];
          }
        }
        if (s.settled || s.blocked){
          clearInterval(timer);
          // The card's remaining detail (failures, the blocked reason) comes from Julia, so hand
          // back to the cell rather than trying to rebuild it here.
          var n = root.querySelector('[data-sw="note"]');
          if (n) n.textContent = s.blocked ? s.blocked : "finished — re-run the cell for detail";
        }
      }
      function tick(){
        if (!document.body.contains(root)) { clearInterval(timer); return; }
        if (!window.slateCall) return;
        window.slateCall("$(ch)", {}).then(paint).catch(function(){ clearInterval(timer); });
      }

      // Buttons. Disabled while the call is in flight so an impatient second click cannot cancel
      // and resume in the same breath.
      root.querySelectorAll('[data-sw-do]').forEach(function(b){
        b.addEventListener('click', function(){
          var was = b.textContent;
          b.disabled = true; b.textContent = "…";
          window.slateCall("$(doch)", { action: b.dataset.swDo }).then(function(s){
            paint(s);
            // The set of applicable buttons changes with the state, and only Julia knows which
            // apply, so hand back to the cell rather than guessing here.
            var n = root.querySelector('[data-sw="note"]');
            if (n) n.textContent = "done — re-run the cell to refresh the controls";
            b.textContent = was;
          }).catch(function(e){
            b.disabled = false; b.textContent = was;
            var n = root.querySelector('[data-sw="note"]');
            if (n) n.textContent = String(e);
          });
        });
      });

      // One tick ALWAYS, so a finished sweep still reports itself to the topbar pill; the repeating
      // timer only starts when there is something left to watch.
      tick();
      if ($(poll ? "true" : "false")) timer = setInterval(tick, interval());
    })();
    </script>""")
end

function Base.show(io::IO, ::MIME"text/plain", r::ShardedResult)
    p = r.plan
    t = r.telemetry
    icon = p.state === :succeeded ? "✅" : p.state === :partial   ? "⚠️" :
           p.state === :exhausted ? "⛔" : p.state === :blocked   ? "🛑" :
           p.state === :cancelled ? "⏹" : p.state === :running   ? "⏳" : "•"
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
    elseif p.state === :cancelled
        println(io, "   Stopped at your request. $(p.shards_done) finished units are kept — ",
                    "`resume!(r)` continues with the remaining $(p.shards_missing).")
    elseif p.state === :partial
        println(io, "   `failures(r)` lists the errors; `retry_failed!(r)` clears them for a retry.")
    elseif p.state === :exhausted
        println(io, "   Attempted $(BatchSweep.MAX_ATTEMPTS)× without landing, so these units are ",
                    "outrunning their resources rather than erroring.")
        println(io, "   Raise the walltime or memory, then `reset!(r)`.")
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
                   submit::Bool = true, cap::Integer = 0, register = nothing,
                   resources = nothing, wait::Bool = false,
                   progress = nothing, pause = nothing, poll::Real = 2.0)
    # Resource overrides do NOT enter the key. Re-running the same body with a longer walltime is
    # the same sweep resumed, not a different one — otherwise the fix for a walltime kill would
    # throw away every unit that had already survived it.
    target = with_resources(target, resources)
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
    # The card's live channel. Registered here rather than by the author, so a sweep cell needs no
    # wiring to be watchable. `register` is the notebook's `slate_on`; outside a notebook (a
    # standalone run, a test) it is simply absent and the card renders static.
    if register !== nothing
        ps, ks = collect(params), keys
        # Positional, NOT a do-block: `slate_on(channel, f)` takes the channel first, and a
        # do-block passes the function first, which registers the pair reversed and leaves the
        # channel silently unreachable.
        #
        # Deliberately unguarded. A swallowed failure here means the card never updates, which
        # looks like the sweep having stalled — much worse than an error naming the cause.
        register(status_channel(key), _args -> status_payload(target, key, ps, ks))
        register(action_channel(key),
                 a -> handle_action(target, key, ps, ks, String(get(a, :action, ""))))
    end

    pl = BatchSweep.plan(root, key; launcher)
    tl = BatchSweep.telemetry(root, key; launcher, plan = pl)
    res = ShardedResult(key, target, collect(params), keys, pl, _rows(root, params, keys), tl)

    # `wait = true` holds the cell open and drives Slate's OWN progress bar and run chip, which is
    # where a reader already looks to see what a notebook is doing. The card alone is buried in one
    # cell's output; this puts the sweep where the rest of the notebook reports itself.
    #
    # Interrupting the cell stops WATCHING, not the sweep: the work is on the cluster and the store
    # remembers it, so the result is returned with whatever has landed rather than raising.
    if wait && progress !== nothing
        try
            while true
                refresh!(res)
                p, t = res.plan, res.telemetry
                bits = ["$(p.shards_done)/$(p.shards_total)"]
                p.shards_failed > 0 && push!(bits, "$(p.shards_failed) failed")
                (t.eta_s >= 0 && !BatchSweep.is_settled(p)) && push!(bits, "~$(_dur(t.eta_s)) left")
                progress(BatchSweep.fraction(p); msg = join(bits, " · "))
                (BatchSweep.is_settled(p) || BatchSweep.is_stuck(p)) && break
                pause === nothing ? Base.sleep(poll) : pause(poll)
            end
            progress(1.0; msg = _state_label(res.plan.state), done = true)
        catch e
            e isa InterruptException || rethrow()
            progress(BatchSweep.fraction(res.plan);
                     msg = "stopped watching — the sweep is still running", done = true)
        end
    end
    return res
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

    # Options may arrive either as plain `key = value` arguments or, when written after a `;`, in a
    # single `:parameters` expression that Julia places FIRST. Both spellings are natural, so
    # flatten them into one list rather than making the caller remember which is accepted.
    opts = Dict{Symbol,Any}()
    positional = Any[]
    for (i, a) in enumerate(args)
        i == bi && continue
        if a isa Expr && a.head === :parameters
            for kw in a.args
                (kw isa Expr && kw.head === :kw) || error("@sweep: unexpected argument $(kw)")
                opts[kw.args[1]] = kw.args[2]
            end
        elseif a isa Expr && a.head === :(=)
            opts[a.args[1]] = a.args[2]
        else
            push!(positional, a)
        end
    end
    length(positional) >= 2 ||
        error("@sweep needs a grid and a target: `@sweep(grid, target) do p … end`")
    grid, target = positional[1], positional[2]

    # The do-block's parameter and body, as written.
    plist = body.args[1]
    param = plist isa Symbol ? plist :
            (plist isa Expr && plist.head === :tuple && length(plist.args) == 1) ? plist.args[1] :
            error("@sweep's do-block takes exactly one parameter")
    inner = body.args[2]

    # Line information is stripped before the body is stringified. It is part of the key, so
    # leaving it in would mean a sweep re-keys — orphaning every result it already has — because a
    # cell moved down the notebook or gained a comment above it.
    body_src = string(param, " -> begin\n", string(_strip_lines(inner)), "\nend")
    names = _capture_names(inner, param)
    setup  = get(opts, :setup, "")
    cap    = get(opts, :cap, 0)
    submit = get(opts, :submit, true)
    res     = get(opts, :resources, nothing)
    waitfor = get(opts, :wait, false)
    # An unknown option is an error rather than a silent no-op: `@sweep(…, wallclock = "2h")` that
    # quietly does nothing is worse than one that says so.
    for k in keys(opts)
        k in (:setup, :cap, :submit, :resources, :wait) ||
            error("@sweep: unknown option `$k` (accepted: setup, cap, submit, resources, wait)")
    end

    quote
        local _names = $(QuoteNode(collect(names)))
        local _caps = $(Sweep)._collect_captures(@__MODULE__, _names, $(QuoteNode(param)))
        # `slate_on` is injected into a notebook's namespace, so it is reachable from here and
        # nowhere else. Picking it up automatically is what lets a sweep cell be live without the
        # author registering anything.
        local _reg = isdefined(@__MODULE__, :slate_on) ?
                     getfield(@__MODULE__, :slate_on) : nothing
        # `slate_progress` drives the cell's bar and the run chip; `pause` is the cancellable sleep,
        # so a `wait`ing sweep stops promptly when the cell is stopped. Both are notebook-injected
        # and simply absent in a standalone run, where waiting degrades to a plain sleep.
        local _prog = isdefined(@__MODULE__, :slate_progress) ?
                      getfield(@__MODULE__, :slate_progress) : nothing
        local _pause = isdefined(@__MODULE__, :pause) ?
                       getfield(@__MODULE__, :pause) : nothing
        $(Sweep).run_sweep($(esc(target)), collect($(esc(grid))), $body_src;
                           setup_src = $(esc(setup)), captures = _caps,
                           cap = $(esc(cap)), submit = $(esc(submit)), register = _reg,
                           resources = $(esc(res)), wait = $(esc(waitfor)),
                           progress = _prog, pause = _pause)
    end
end

end # module Sweep
