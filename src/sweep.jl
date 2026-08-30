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
import Dates   # the ETA as a wall-clock finish time, not only a remaining duration
import TOML    # reading sweep descriptors straight off a store (cluster_status)

# The def extractor + source-tree digest, which `env_source_fingerprint` below is built on: it is
# how "has the science package changed?" is answered, and it is the same answer the memo layer needs
# for "has a function this cell calls changed?". Dependency-free by design, and already included
# this way by the worker and by its own tests.
Base.include(@__MODULE__, joinpath(@__DIR__, "defname.jl"))

# Reaching a store the hub has no filesystem access to — the mirror, the multiplexed connection, and
# the rsync that keeps them in step. Separate because it is transport with no opinion about sweeps.
Base.include(@__MODULE__, joinpath(@__DIR__, "remotestore.jl"))

# Where a dataset index is kept so a scratch purge cannot take it. Included rather than imported
# because this file is loaded by the WORKER too, which has no `KaimonSlate.SlateHome` — and the two
# must agree on the path, or a notebook and its worker would remember indexes in different places.
if !isdefined(@__MODULE__, :SlateHome)
    Base.include(@__MODULE__, joinpath(@__DIR__, "slate_home.jl"))
end

# The env-preparation policy shared by the notebook fork and the remote provisioner. envprep.jl is
# pure TOML/file operations with no transport of its own, precisely so a new transport can reuse it:
# batch is the third, after the local filesystem fork and ssh/rsync.
Base.include(@__MODULE__, joinpath(@__DIR__, "envprep.jl"))

const P = parentmodule(@__MODULE__)
const MemoStore = P.MemoStore
const SlateTask = P.SlateTask
const BatchLauncher = P.BatchLauncher
const BatchSweep = P.BatchSweep

# Deliberately small. These names go into EVERY notebook namespace, where an injected binding
# shadows whatever the author's own packages export — silently, because a definition beats a
# `using`. Everything a sweep can be ASKED is a property of the result (`r.state`, `r.results`,
# `r.eta`), and everything it can be TOLD is a qualified call (`Sweep.cancel!(r)`).
export paramgrid, @sweep, SweepTarget, LocalTarget, SlurmTarget

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
    # Keyed by the parent's SOURCE, not only its Project/Manifest: a task process is fresh and has
    # no Revise, so an edited `src/` that does not move the key means the units keep running the old
    # code. The env directory changes when the source does, which is also what makes the rebuild
    # automatic rather than something to remember.
    fp = env_source_fingerprint(parent)
    key = first(string(hash((fp, extras)); base = 16), 12)
    envdir = joinpath(root, "taskenv", key)

    if isfile(joinpath(envdir, "Manifest.toml")) &&
       (isfile(_env_stamp_file(envdir)) && strip(read(_env_stamp_file(envdir), String)) == fp)
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
    write(_env_stamp_file(envdir), fp)
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
    provision_payload!(host, root_remote) -> path

Put the task runner where a compute node can load it, and return the path it will use.

The runner is Slate's own code, not the user's — a handful of stdlib-only files that every job
`include`s. It ships the same way the task environment does, over ssh, because that is the only way
in: a cluster's filesystem is reachable from its nodes, not from here. Idempotent and cheap; rsync
sends nothing when the files are unchanged.
"""
function provision_payload!(host::AbstractString, root_remote::AbstractString)
    dst = "$(root_remote)/src"
    ok, out = _ssh_run(host, "mkdir -p $(dst)")
    ok || error("could not create $(dst) on $(host): $(strip(out))")
    src = dirname(String(first(methods(paramgrid)).file))
    files = [joinpath(src, f) for f in SlateTask.PAYLOAD_FILES]
    dest = isempty(host) ? dst : "$(host):$(dst)"
    try
        run(pipeline(`rsync -a $(files) $(dest)/`; stdout = devnull, stderr = devnull))
    catch e
        error("could not ship the task runner to $(host):$(dst) ($(sprint(showerror, e)))")
    end
    return "$(dst)/slatetask.jl"
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
    # Source-inclusive, for the same reason as `task_env!`: the cluster's copy is rsync'd once, so
    # an edit the fingerprint cannot see is an edit the compute nodes never get.
    fp = env_source_fingerprint(parent)
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
function SlurmTarget(host = ""; root = "", root_remote = root, payload = "",
                     parent = "", project = nothing,
                     resources = (; cpus = 1, mem = "2G", walltime = "01:00:00", partition = ""),
                     chunk = 16, account = "", qos = "", prologue = "", julia = "julia")
    proj = project !== nothing ? String(project) :
           provision_remote_env!(String(host), String(root_remote), String(parent);
                                 julia = String(julia), prologue = String(prologue))
    # The runner is Slate's own code and its location on the cluster is Slate's business, so it is
    # shipped rather than configured. Naming one is still allowed, for a site that stages it itself.
    pay = isempty(String(payload)) ? provision_payload!(String(host), String(root_remote)) :
          String(payload)
    SlurmTarget(String(host), String(root), String(root_remote), proj, String(pay),
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

# The scheduler settings a `#%% sweep` cell may carry on its header (engine.jl `cell_attrs`), e.g.
#
#     #%% sweep id=scan walltime=02:00:00 partition=gpu mem=16G
#
# These are the numbers you change WHILE a job is queued or after it was killed. Keeping them off
# the Julia source means adjusting one does not edit code — and because resources are deliberately
# not part of a sweep's key, raising a walltime RESUMES the sweep instead of discarding the units
# that already survived.
const _ATTR_RESOURCES = (:cpus, :mem, :walltime, :partition, :account, :qos, :gpus, :nodes)

# ── Named compute targets ────────────────────────────────────────────────────────────────────
# A cluster is defined ONCE for the notebook (engine.jl's `Slate.clusters` footer, edited from the
# ⎈ on a sweep cell) and referenced by name: `#%% sweep cluster=hpc`. Three cells that run on the
# same partition then say so once, and changing where the work goes is one edit rather than three.
#
# `kind` selects the backend. SLURM is the one that is real today; `local` runs the same cells with
# no scheduler at all. PBS and Kubernetes are the reason this dispatches on a STRING out of
# configuration rather than on a Julia type written into a cell — adding one is a new branch here
# and a new `Launcher`, not a change to any notebook.
"""
    cluster(spec) -> SweepTarget

Build a target from a notebook cluster definition (a flat `Dict` of strings). Called for you when a
sweep cell names one with `cluster=`; call it directly only to inspect what a definition resolves to.
"""
function cluster(spec::AbstractDict)
    a = cluster_args(spec)
    a.kind == "local" && return LocalTarget(; a.root, a.parent, a.chunk)
    return SlurmTarget(a.host; a.root, a.root_remote, a.parent, a.payload, a.chunk,
                       a.account, a.qos, a.prologue, a.resources)
end

"""
    cluster_args(spec) -> NamedTuple

What a cluster definition MEANS, without building anything. Kept separate from `cluster` because
constructing a target provisions an environment on the far side — so validating a definition, or
showing what it resolves to, must not require reaching the cluster.
"""
function cluster_args(spec::AbstractDict)
    get_(k, d = "") = String(get(spec, k, d))
    kind = lowercase(get_("kind", "slurm"))
    name = get_("name", "cluster")
    kind in ("slurm", "local") ||
        error("cluster `$name` has kind `$kind`; this build supports `slurm` and `local`. " *
              "PBS and Kubernetes are separate backends, not options here.")
    root = get_("root")
    host = get_("host")
    root_remote = get_("root_remote")
    # A cluster reached over ssh has ONE store, and it is the cluster's — `root` is for a local run,
    # or for the unusual case of a store this notebook has mounted. Requiring both was a hangover
    # from assuming a shared filesystem.
    if kind == "local" || isempty(host)
        isempty(root) && isempty(root_remote) &&
            error("cluster `$name` has no `root` — where its store lives on this machine")
        isempty(root) && (root = root_remote)
    else
        isempty(root_remote) &&
            error("cluster `$name` has no `root_remote` — its store ON the cluster. Put it on " *
                  "scratch: \$HOME is small and is not built for parallel writes.")
    end
    parent = get_("project")
    isempty(parent) && (parent = dirname(Base.active_project()))
    chunk = something(tryparse(Int, get_("chunk", "8")), 8)
    # The task runner is Slate's own code and is shipped during provisioning, so naming a path is
    # only for a site that stages it itself.
    payload = get_("payload")
    res = attr_resources(spec)
    return (; kind, name, root, parent, chunk, payload,
              root_remote = isempty(root_remote) ? root : root_remote,
              host, account = get_("account"), qos = get_("qos"),
              prologue = get_("prologue"),
              resources = res === nothing ? NamedTuple() : res)
end

# Resolve the target a sweep cell asked for: an explicit one written in the cell wins, else the
# `cluster=` named on its header, else nothing to run on — which is worth an error naming the
# clusters that ARE defined, because the usual cause is a typo or a renamed definition.
function resolve_target(explicit, attrs::AbstractDict, clusters::AbstractDict)
    explicit === nothing || return explicit
    nm = String(get(attrs, "cluster", ""))
    if isempty(nm)
        isempty(clusters) &&
            error("@sweep: no target. Give one — `@sweep(grid, mytarget) do … end` — or define a " *
                  "cluster (⎈ on a sweep cell) and name it on the header: `#%% sweep cluster=<name>`.")
        error("@sweep: no target. Name one of this notebook's clusters on the cell header " *
              "(`#%% sweep cluster=<name>`): " * join(sort!(collect(keys(clusters))), ", "))
    end
    spec = get(clusters, nm, nothing)
    spec === nothing &&
        error("@sweep: no cluster named `$nm` in this notebook. Defined: " *
              (isempty(clusters) ? "(none)" : join(sort!(collect(keys(clusters))), ", ")))
    return cluster(merge(Dict{String,Any}("name" => nm), spec))
end

# String → the type the JobSpec wants. Counts are integers; everything else is a scheduler string
# passed through as written (`mem=16G`, `walltime=02:00:00`), because inventing a duration syntax
# here would only stand between the author and the scheduler's own documentation.
function attr_resources(attrs::AbstractDict)
    res = Dict{Symbol,Any}()
    for k in _ATTR_RESOURCES
        v = get(attrs, String(k), nothing)
        v === nothing && continue
        if k in (:cpus, :gpus, :nodes)
            n = tryparse(Int, v)
            n === nothing && error("@sweep: `$k=$v` on the cell header must be an integer")
            res[k] = n
        else
            res[k] = String(v)
        end
    end
    isempty(res) && return nothing
    return NamedTuple(res)
end

"""
    attr_lazy(attrs) -> Bool

Whether the cell asked for its results to be stored ADDRESSABLY (`data=lazy`) rather than brought
back whole (`data=eager`, the default). Configuration rather than code: the sweep body is identical
either way, and the choice is about the size of what comes out, which is a property of the run.
"""
function attr_lazy(attrs::AbstractDict)
    v = get(attrs, "data", nothing)
    v === nothing && return false
    s = lowercase(strip(String(v)))
    s in ("lazy", "eager") ||
        error("@sweep: `data=$v` on the cell header must be `lazy` or `eager`")
    return s == "lazy"
end

"A `chunk=` header attribute, or `nothing`. How many units ride one scheduler job."
function attr_chunk(attrs::AbstractDict)
    v = get(attrs, "chunk", nothing)
    v === nothing && return nothing
    n = tryparse(Int, v)
    (n === nothing || n < 1) && error("@sweep: `chunk=$v` on the cell header must be a positive integer")
    return n
end

with_chunk(t::LocalTarget, n) = n === nothing ? t :
    LocalTarget(t.root, t.project, t.payload, n)
with_chunk(t::SlurmTarget, n) = n === nothing ? t :
    SlurmTarget(t.host, t.root, t.root_remote, t.project, t.payload,
                t.resources, n, t.account, t.qos, t.prologue)

store_root(t::LocalTarget) = t.root
# The hub plans against the MIRROR for a remote cluster — a local directory holding a copy of the
# store's metadata. `root_remote` stays the job's view and never changes.
store_root(t::SlurmTarget) = plan_root(t)
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

# `_strip_lines` (defname.jl, included above) drops LineNumberNodes, so a body's text depends only
# on the code and not on where it sits in a file — the same normalisation the def-body digest needs.

# The environment a unit runs in is part of what computed the result, so it is part of the key.
#
# Nothing new has to be digested for this: the provisioner already NAMES the task environment after
# its parent's fingerprint (`task_env!` / `provision_remote_env!` both key the directory by it), so
# the env path's last component IS that fingerprint. Editing the science package moves the env, and
# moving the env re-keys the sweep.
#
# Without it, the fabric would silently mix results from two versions of the code — the exact thing
# it refuses to do for the body text. A task process is fresh and has no Revise, so an edit to the
# package the body calls into changes what every unit computes while leaving the body identical.
env_key(target::SweepTarget) = basename(rstrip(String(target.project), '/'))

function sweep_key(body_src, setup_src, captures, envkey = "", summary_src = "")
    caps = join(sort(["$k=$(_digest_of(v))" for (k, v) in captures]), ";")
    return "sw" * first(_hex(string(body_src, "\0", setup_src, "\0", caps, "\0", envkey,
                                    "\0", summary_src)), 16)
end

shard_key(sweep, param) = string(sweep, "_s", first(_digest_of(param), 12))
chunk_key(run, i) = string(run, "_c", i)

# A sweep's identity and a REQUEST's identity are not the same thing, and conflating them breaks
# the pattern the fabric exists to encourage. A pilot over four points and the full sweep over four
# thousand deliberately share a body, so they share a sweep key, so the second reuses the first's
# results. But their chunking, plan, attempt budget, cancellation marker and card describe
# DIFFERENT sets of units. Key those by the grid too, or the two cells overwrite each other's chunk
# descriptors and each one renders the other's progress.
#
# Shard keys stay derived from the SWEEP key, which is what makes the reuse work: the same
# parameters under the same body are the same unit however they were requested.
run_key(sweep, keys) = string(sweep, "_r", first(_hex(join(keys, ",")), 10))

# ── Result ───────────────────────────────────────────────────────────────────────────────────

"""
    ShardedResult

A sweep's results, usable while incomplete. Indexable and iterable over rows of
`(; params, status, value, ran_on, ms)`, where `status` is `"ok"`, `"error"`, or `""` for a shard
that has not run.
"""
mutable struct ShardedResult
    key::String                   # the SWEEP: body + setup + captures. What makes results reusable.
    run::String                   # this REQUEST: the sweep over THIS grid. What is scheduled.
    target::SweepTarget
    params::Vector{Any}
    keys::Vector{String}
    plan::BatchSweep.Plan
    rows::Vector{NamedTuple}
    telemetry::BatchSweep.Telemetry
    plot::Any                     # rows -> chart, drawn live on the card (nothing = no chart)
end

Base.length(r::ShardedResult) = length(getfield(r, :rows))
Base.getindex(r::ShardedResult, i) = getfield(r, :rows)[i]
Base.iterate(r::ShardedResult, s = 1) =
    s > length(getfield(r, :rows)) ? nothing : (getfield(r, :rows)[s], s + 1)
Base.eltype(::Type{ShardedResult}) = NamedTuple

# A sweep has a large vocabulary — state, six counts, rate, ETA, stall, the successful rows, the
# failed ones — and a free function for each would put names as generic as `finished`, `failures`,
# `eta`, `blocked` and `values` into every notebook namespace, where an injected binding SHADOWS
# whatever the author's own packages export, silently. Properties are namespaced by the object, so
# there is nothing to collide with and nothing to import.
#
# Questions are properties; ACTIONS stay functions (`Sweep.cancel!`, `Sweep.reset!`) because a
# property that mutates on read is a trap.
const _DERIVED = (:state, :total, :done, :ok, :failed, :pending, :fraction, :percent,
                  :eta, :rate, :idle, :stalled_for, :blocked, :settled,
                  :results, :summaries, :errors, :hosts, :bytes, :armed, :dataset)

function Base.getproperty(r::ShardedResult, s::Symbol)
    s in fieldnames(ShardedResult) && return getfield(r, s)
    p, t = getfield(r, :plan), getfield(r, :telemetry)
    rows = getfield(r, :rows)
    s === :state      && return display_state(p, BatchSweep.is_armed(store_root(getfield(r, :target)),
                                                                     getfield(r, :run)))
    s === :armed      && return BatchSweep.is_armed(store_root(getfield(r, :target)), getfield(r, :run))
    s === :total      && return p.shards_total
    s === :done       && return p.shards_done
    s === :ok         && return p.shards_ok
    s === :failed     && return p.shards_failed
    s === :pending    && return p.shards_missing
    s === :fraction   && return BatchSweep.fraction(p)
    s === :percent    && return round(100 * BatchSweep.fraction(p); digits = 1)
    s === :settled    && return BatchSweep.is_settled(p)
    # Seconds until the sweep finishes at the observed rate; -1 when nothing has finished yet.
    s === :eta        && return t.eta_s
    s === :rate       && return t.rate_per_s
    s === :idle       && return t.idle_s
    # How long the sweep has LOOKED stopped, or 0.0 if it looks healthy.
    s === :stalled_for && return BatchSweep.stalled_for(t)
    # Why nothing more will be submitted ("" = not blocked).
    s === :blocked    && return p.blocked
    # The addressable output of a `data=lazy` sweep, spanning every unit that has landed. Built
    # from manifests alone, so asking for it — and asking it for its schema and size — reads none
    # of the data it describes.
    s === :dataset    && return _dataset_of(store_root(getfield(r, :target)),
                                            getfield(r, :params), getfield(r, :keys),
                                            getfield(r, :run), source_of(getfield(r, :target)))
    s === :results    && return [row for row in rows if row.status == "ok"]
    # The charting values, straight from the manifests. This is the accessor analysis should reach
    # for: it is the same cost at four units and four million.
    s === :summaries  && return [row.summary for row in rows if row.status == "ok"]
    s === :errors     && return [row for row in rows if row.status == "error"]
    s === :bytes      && return sum(row.bytes for row in rows; init = 0)
    s === :hosts      && return unique([row.ran_on for row in rows if !isempty(row.ran_on)])
    throw(ArgumentError("ShardedResult has no property `$s`. Try one of: " *
                        join(string.(propertynames(r)), ", ")))
end

Base.propertynames(::ShardedResult) = (fieldnames(ShardedResult)..., _DERIVED...)

"""
    ShardRef

A handle on one unit's result. Holds no data: its size, element type and byte count come from the
manifest, and bytes are read only when you index it.

    ref = r.rows[7].value
    size(ref), eltype(ref)     # metadata — no I/O
    ref[64, :, :]              # mmapped slice — only the touched pages are read
    ref[]                      # the whole value

Indexing an isbits array mmaps the blob read-only, so taking a corner of a multi-gigabyte field
costs the pages it covers rather than the field.
"""
struct ShardRef
    root::String
    binding::Dict{String,Any}
    dims::Vector{Int}
    eltype::String
    type::String
    bytes::Int
    src::Any            # where the BYTES are — the mirror holds manifests, never results
end
ShardRef(root, binding, dims, eltype, type, bytes) =
    ShardRef(root, binding, dims, eltype, type, bytes, LocalSource(root))

# A blob's local path, fetching it from the cluster first when the store is not one this hub can
# open. Whole-value reads are the eager path — the one a sweep that returns an ordinary result uses
# — and they were reading straight out of the mirror, where blobs deliberately never go.
_ref_path(x::ShardRef) = blob_file(x.src, String(x.binding["blob"]), x.bytes)

Base.size(x::ShardRef) = Tuple(x.dims)
Base.length(x::ShardRef) = isempty(x.dims) ? 1 : prod(x.dims)
Base.ndims(x::ShardRef) = length(x.dims)
Base.eltype(x::ShardRef) = x.eltype
Base.sizeof(x::ShardRef) = x.bytes

"Materialize the whole value. The one call that reads all of it, and it says so."
Base.getindex(x::ShardRef) =
    SlateTask.load_binding(x.root, x.binding; path = _ref_path(x))

# `zc` mmaps the blob rather than copying it, so a slice faults in only the pages it covers. The
# mapping is read-only; the slice is copied out of it, so the caller owns ordinary memory.
Base.getindex(x::ShardRef, i...) =
    getindex(SlateTask.load_binding(x.root, x.binding; zc = true, path = _ref_path(x)), i...)

Base.show(io::IO, x::ShardRef) =
    print(io, "ShardRef(", x.type,
          isempty(x.dims) ? "" : " " * join(x.dims, "×"), ", ", _bytes(x.bytes), ")")

"""
    ArtifactRef

A file a unit produced and left where it ran — model weights, a checkpoint, a rendered video. The
notebook holds its name and size; the bytes stay in the cluster-side store until something asks.

    a = r.rows[3].artifacts[1]
    a.name, a.bytes             # no I/O
    Sweep.fetch(a, "local.mp4") # bring this one back, deliberately
"""
struct ArtifactRef
    root::String
    name::String
    blob::String
    bytes::Int
    src::Any            # LocalSource | SshSource — where the bytes are, which is not the mirror
end
ArtifactRef(root, name, blob, bytes) =
    ArtifactRef(String(root), String(name), String(blob), Int(bytes), LocalSource(String(root)))

Base.show(io::IO, a::ArtifactRef) = print(io, "ArtifactRef(", a.name, ", ", _bytes(a.bytes), ")")

# An artifact is whole-file by nature — weights, a checkpoint, a video — so there is no slice to
# read, and `blob_file` brings the whole blob across once and caches it by content.
_art_path(a::ArtifactRef) = blob_file(a.src, a.blob, a.bytes)

"Copy one artifact out of the store to `dest`. The only call that moves an artifact's bytes."
function fetch(a::ArtifactRef, dest::AbstractString)
    cp(_art_path(a), dest; force = true)
    return dest
end

"Read one artifact's bytes without writing a file."
bytes(a::ArtifactRef) = read(_art_path(a))

_arts(root, m, src = LocalSource(String(root))) = ArtifactRef[
    ArtifactRef(String(root), String(get(a, "name", "")), String(get(a, "blob", "")),
                Int(get(a, "bytes", 0)), src)
    for a in get(m, "artifacts", Any[]) if a isa AbstractDict]

# ── Datasets ─────────────────────────────────────────────────────────────────────────────────
# What a `data=lazy` sweep hands the notebook: one logical table (or one set of array parts) over
# output that stays where it was written. Every field a reader asks about first — the schema, the
# row count, the size — comes from the index, so describing a dataset costs manifest reads no
# matter what it weighs. Only a slice moves bytes, and only the bytes of that slice.

# ── Transfer accounting ──────────────────────────────────────────────────────────────────────
# A dataset exists so that reads stay small; the only way to know whether they have is to count
# them. Every call that moves bytes records what it moved, so the question "how much of this have I
# actually pulled?" has an answer rather than an assumption.
#
# Counted at the READ, not at the transport: the byte figure is what the slice asked for, which is
# the same whether it came off a local mmap or over the blob channel. That keeps the number
# meaningful when the backend changes underneath it.

struct Transfer
    at::Float64          # unix time
    label::String        # the sweep run this came from
    root::String         # the store it came OUT of — which is what makes it a cluster's traffic
    kind::Symbol         # :rows | :elements
    bytes::Int
    chunks::Int          # stored pieces opened
    ms::Float64
end

const _XFER = Transfer[]
const _XFER_LOCK = ReentrantLock()
const _XFER_MAX = 500    # a rolling window; the totals below are kept separately so they never lapse
const _XFER_TOTALS = Dict{String,Tuple{Int,Int,Float64}}()   # label → (bytes, chunks, ms)

function _record!(label, root, kind, bytes, chunks, ms)
    lock(_XFER_LOCK) do
        push!(_XFER, Transfer(time(), String(label), String(root), kind,
                              Int(bytes), Int(chunks), Float64(ms)))
        length(_XFER) > _XFER_MAX && deleteat!(_XFER, 1:(length(_XFER) - _XFER_MAX))
        for k in (String(label), "root:" * String(root))     # totalled per sweep AND per store
            b, c, t = get(_XFER_TOTALS, k, (0, 0, 0.0))
            _XFER_TOTALS[k] = (b + Int(bytes), c + Int(chunks), t + Float64(ms))
        end
    end
    return nothing
end

"Bytes this session has read out of `label`'s dataset (0 if none)."
transferred(label::AbstractString) = lock(_XFER_LOCK) do
    get(_XFER_TOTALS, String(label), (0, 0, 0.0))[1]
end

"""
    transfers(; label = "", n = 8) -> NamedTuple

What this session has actually moved: total bytes, the pieces opened to get them, and the observed
rate. `recent` is the last `n` reads, newest first — which is where a surprise shows up as one
oversized row rather than a slow drift.
"""
function transfers(; label::AbstractString = "", n::Integer = 8)
    lock(_XFER_LOCK) do
        # A label is either a sweep run or a `root:<store>` — the same reads grouped two ways, so
        # the row filter has to know which it was handed or a per-store view reports no reads at all.
        rows = if isempty(label)
            _XFER
        elseif startswith(String(label), "root:")
            r = String(label)[6:end]
            [x for x in _XFER if x.root == r]
        else
            [x for x in _XFER if x.label == String(label)]
        end
        b, c, ms = if isempty(label)
            bb = cc = 0; tt = 0.0
            for (k, (x, y, z)) in _XFER_TOTALS
                startswith(k, "root:") && continue   # the per-store mirror of the same bytes
                bb += x; cc += y; tt += z
            end
            (bb, cc, tt)
        else
            get(_XFER_TOTALS, String(label), (0, 0, 0.0))
        end
        return (; bytes = b, pretty = _bytes(b), chunks = c, seconds = round(ms / 1000; digits = 3),
                  rate = ms > 0 ? _bytes(round(Int, b / (ms / 1000))) * "/s" : "—",
                  reads = length(rows),
                  recent = [(; kind = x.kind, bytes = _bytes(x.bytes), chunks = x.chunks,
                               ms = round(x.ms; digits = 1), label = x.label)
                            for x in Iterators.reverse(rows)][1:min(max(0, Int(n)), length(rows))])
    end
end

"Forget the accounting — a fresh baseline for measuring one query."
function reset_transfers!()
    lock(_XFER_LOCK) do; empty!(_XFER); empty!(_XFER_TOTALS); end
    return nothing
end

# ── What a cluster is doing ──────────────────────────────────────────────────────────────────
# A cluster is defined once for the notebook and referenced by name from any number of cells, so
# "what is going on with it" is a question about the CLUSTER, not about whichever cell you happen to
# be looking at. Everything here is derived — from the store's manifests and the scheduler's own
# answer — so it reports what is true rather than what some cell last recorded.

"Every sweep descriptor in a store, newest first. One directory listing plus a manifest read each."
function store_sweeps(root::AbstractString)
    out = Tuple{String,Int}[]
    d = joinpath(root, "manifests")
    isdir(d) || return out
    for f in readdir(d; join = true)
        endswith(f, ".toml") || continue
        m = try; TOML.parsefile(f); catch; continue; end
        String(get(m, "kind", "")) == BatchSweep.KIND_SWEEP || continue
        push!(out, (basename(f)[1:end-5], Int(get(m, "created", 0))))
    end
    sort!(out; by = x -> -x[2])
    return out
end

"""
    sweep_bytes(root, sweep) -> Int

How much output one sweep has PRODUCED, from its manifests — the number that says whether pulling
it back is reasonable. Counts a unit's stored result whichever form it took, so an addressable
dataset and a whole value are comparable.
"""
function sweep_bytes(root::AbstractString, sweep::AbstractString)
    total = 0
    for c in (try; BatchSweep.sweep_chunks(root, sweep); catch; String[]; end)
        for k in BatchSweep.chunk_shards(root, c)
            m = MemoStore.read_manifest(root, k)
            m === nothing && continue
            d = get(m, "dataset", nothing)
            if d isa AbstractDict
                total += Int(get(d, "bytes", 0))
            else
                for b in get(m, "bindings", Any[])
                    b isa AbstractDict && (total += Int(get(b, "bytes", 0)))
                end
            end
            for a in get(m, "artifacts", Any[])
                a isa AbstractDict && (total += Int(get(a, "bytes", 0)))
            end
        end
    end
    return total
end

"""
    store_size(src) -> (; bytes, blobs)

How much result data is sitting in a store, and in how many blobs. Asked of the STORE, which for a
cluster is not the mirror: the mirror holds the descriptors this hub pushed and none of the output,
so measuring it reported kilobytes for a store holding tens of gigabytes — directly above the
per-sweep sizes that said otherwise. (The source-aware methods are with the sources, below.)
"""
function store_size(root::AbstractString)
    b = 0; n = 0
    d = joinpath(root, "blobs")
    isdir(d) || return (; bytes = 0, blobs = 0)
    for (dir, _, files) in walkdir(d), f in files
        s = try; filesize(joinpath(dir, f)); catch; 0; end
        s > 0 && (b += s; n += 1)
    end
    return (; bytes = b, blobs = n)
end

"""
    cluster_status(name) -> ClusterStatus

What a named cluster is doing right now: the sweeps in its store and how far along they are, what
the scheduler says is live, how much output is sitting there, and how much of it this session has
pulled back. Rendered as a panel in a notebook; also a plain value you can read fields off.
"""
struct ClusterStatus
    name::String
    spec::Dict{String,String}
    root::String
    sweeps::Vector{NamedTuple}
    live::Dict{String,Symbol}
    store::NamedTuple
    xfer::NamedTuple
    err::String
end

function cluster_status(name::AbstractString = "";
                        clusters::AbstractDict = _ctx_clusters())
    nm = String(name)
    if isempty(nm)
        length(clusters) == 1 || error("name a cluster: " *
            (isempty(clusters) ? "this notebook defines none (⎈ on a sweep cell)" :
             join(sort(collect(keys(clusters))), ", ")))
        nm = first(keys(clusters))
    end
    spec = get(clusters, nm, nothing)
    spec === nothing && error("no cluster `$nm` in this notebook — defined: " *
                              (isempty(clusters) ? "(none)" : join(sort(collect(keys(clusters))), ", ")))
    spec = Dict{String,String}(String(k) => String(v) for (k, v) in spec)
    t = cluster(spec)
    root = store_root(t)
    err = ""
    rows = NamedTuple[]
    live = Dict{String,Symbol}()
    l = launcher_for(t)
    try
        for (sw, created) in store_sweeps(root)
            p = BatchSweep.plan(root, sw; launcher = l)
            # NOT `t`: that is the target, and everything after this loop still needs it.
            tel = BatchSweep.telemetry(root, sw; launcher = l, plan = p)
            push!(rows, (; sweep = sw, created,
                           state = display_state(p, BatchSweep.is_armed(root, sw)),
                           total = p.shards_total, done = p.shards_done,
                           ok = p.shards_ok, failed = p.shards_failed,
                           missing = p.shards_missing, blocked = p.blocked,
                           armed = BatchSweep.is_armed(root, sw),
                           rate = tel.rate_per_s, eta = tel.eta_s,
                           idle = BatchSweep.stalled_for(tel),
                           hosts = unique(String[r.ran_on for r in BatchSweep.results(root, sw)
                                                 if !isempty(String(r.ran_on))]),
                           stored = sweep_bytes(root, sw),
                           read = transferred(sw)))
        end
        # What the SCHEDULER says, not what we last wrote down — the difference between the two is
        # exactly the failure this answers ("the store says running, squeue has never heard of it").
        subs = BatchSweep.known_submissions(root)
        isempty(subs) || (live = BatchLauncher.poll(l, root, collect(keys(subs))))
    catch e
        err = first(sprint(showerror, e), 200)
    end
    return ClusterStatus(nm, spec, root, rows, live, store_size(source_of(t)),
                         transfers(; label = "root:" * root), err)
end

# The notebook's cluster definitions, from the evaluating cell's context. Empty outside a cell.
function _ctx_clusters()
    sctx = get(task_local_storage(), :slate_ctx, nothing)
    (sctx !== nothing && hasproperty(sctx, :clusters)) && return sctx.clusters
    return Dict{String,Dict{String,String}}()
end

function Base.show(io::IO, ::MIME"text/plain", s::ClusterStatus)
    println(io, "cluster ", s.name, " — ", get(s.spec, "kind", "?"),
            haskey(s.spec, "host") && !isempty(s.spec["host"]) ? " @ " * s.spec["host"] : "")
    println(io, "   store   ", s.root)
    println(io, "           ", _bytes(s.store.bytes), " in ", s.store.blobs, " blobs")
    nlive = count(v -> v in (:running, :pending), values(s.live))
    println(io, "   jobs    ", isempty(s.live) ? "none submitted" :
            string(nlive, " live of ", length(s.live), " known"))
    println(io, "   read    ", s.xfer.pretty, " in ", s.xfer.reads, " reads · ", s.xfer.rate)
    isempty(s.err) || println(io, "   ⚠ ", s.err)
    if isempty(s.sweeps)
        println(io, "   no sweeps in this store yet")
    else
        println(io, "   ", rpad("sweep", 20), rpad("state", 12), rpad("units", 13),
                rpad("stored", 11), "read")
        for r in first(s.sweeps, 12)
            println(io, "   ", rpad(first(r.sweep, 18), 20), rpad(String(r.state), 12),
                    rpad(string(r.done, "/", r.total, r.failed > 0 ? " ($(r.failed)✗)" : ""), 13),
                    rpad(r.stored == 0 ? "—" : _bytes(r.stored), 11),
                    r.read == 0 ? "—" : _bytes(r.read) *
                        (r.stored > 0 ? " ($(round(100 * r.read / r.stored; digits = 1))%)" : ""))
        end
        length(s.sweeps) > 12 && println(io, "   … and ", length(s.sweeps) - 12, " more")
    end
    return nothing
end

# ── Where a dataset's bytes are read FROM ────────────────────────────────────────────────────
# Two topologies, one API. Slate on a login node sees the cluster's store as a directory, and a
# slice is an mmap — the kernel does the ranged fetch and nothing crosses a network at all. Slate on
# a laptop sees a host name and a path on the far side of it, and the same slice becomes a ranged
# read over ssh.
#
# ssh rather than a daemon on the cluster: a batch fabric already reaches the scheduler that way,
# compute nodes write to a shared filesystem and there is nothing to run a server on. `dd` with an
# offset is available on every login node there has ever been, and it needs no port, no key exchange
# and no process left behind.

"A store the hub can open directly — a shared mount, or the same machine."
struct LocalSource
    root::String
end

"A store reachable only through a login node. Ranges are read over ssh; nothing else is copied."
struct SshSource
    host::String
    root::String       # the path AS THE HOST SEES IT
end

source_of(t::LocalTarget) = LocalSource(t.root)
# A SlurmTarget with no host runs its client tools here, so its store is here too. With a host the
# blobs are THERE, and reading them means byte ranges over ssh — `root_remote`, the path the host
# uses, not the mirror the hub plans against.
source_of(t::SlurmTarget) =
    isempty(t.host) ? LocalSource(t.root) : SshSource(t.host, t.root_remote)

# ── The store the hub plans against ──────────────────────────────────────────────────────────
# For a remote cluster this is the local MIRROR, not the cluster path: `plan`, `telemetry`,
# `results` and `status_payload` all walk manifests, and they go on doing that against a directory
# on this machine. What changes is that the directory is a copy, refreshed by one rsync.
#
# Cached per (host, root) so the mirror — and the ssh control socket behind it — is shared by every
# sweep pointed at the same cluster, rather than one per cell.
const _STORES = Dict{Tuple{String,String},RemoteStore}()
const _STORES_LOCK = ReentrantLock()

function remote_store(t::SlurmTarget)
    lock(_STORES_LOCK) do
        get!(_STORES, (t.host, t.root_remote)) do
            s = RemoteStore(t.host, t.root_remote)
            ensure_root!(s)
            s
        end
    end
end

"Where this hub reads and writes store METADATA. Local for a local target; the mirror for a cluster."
plan_root(t::LocalTarget) = t.root
plan_root(t::SlurmTarget) = isempty(t.host) ? t.root : remote_store(t).mirror

"Refresh the hub's view of a store before planning against it. No-op when the store is local."
sync_in!(::LocalTarget) = true
sync_in!(t::SlurmTarget) = isempty(t.host) ? true : pull_meta!(remote_store(t))

# Reconcile, and send back what it wrote IF it submitted. `jobs/` is hub-owned — the submission
# index and the attempt counts — and the store has to end up holding it: a fresh hub reads it to
# find work this one started, and the counts are supposed to outlive the hub that made them. But a
# card polls this on a timer, so the round trip is worth paying only when something changed. The
# attempt counts are the signal, because they move on exactly the submissions that went out.
function reconcile_and_sync!(target::SweepTarget, run::AbstractString, launcher; kw...)
    root = store_root(target)
    before = BatchSweep.read_attempts(root)
    p = BatchSweep.reconcile!(root, run, launcher, specfn_for(target); kw...)
    BatchSweep.read_attempts(root) == before || sync_out!(target; dirs = ("jobs",))
    return p
end

"Send what the hub has written — descriptors, their blobs, markers — to the store. `dirs` narrows
it to part of that, for the callers that have just touched one thing."
sync_out!(::LocalTarget; dirs = nothing) = true
sync_out!(t::SlurmTarget; dirs = nothing) =
    isempty(t.host) ? true :
    (dirs === nothing ? push_meta!(remote_store(t)) : push_meta!(remote_store(t); dirs))

"""
    forget_results!(target, keys)

Drop these units' results for good — from the hub's view AND from the store. Deleting only locally
would be undone by the next sync, which reads the store as the truth; that is right for everything
except a deletion someone asked for.
"""
function forget_results!(t::SweepTarget, keys)
    root = store_root(t)
    n = 0
    for k in keys; MemoStore.drop_manifest(root, k) && (n += 1); end
    t isa SlurmTarget && !isempty(t.host) &&
        forget!(remote_store(t), ["manifests/" * String(k) * ".toml" for k in keys])
    return n
end

Base.show(io::IO, s::LocalSource) = print(io, "local:", s.root)
Base.show(io::IO, s::SshSource) = print(io, s.host, ":", s.root)

"The shell that reads `len` bytes at `offset` from a blob. Pure, so it is testable without a host."
function range_command(root::AbstractString, blob::AbstractString, offset::Integer, len::Integer)
    p = joinpath(root, "blobs", "sha256", String(blob)[1:2], String(blob))
    # `dd` with a block-sized skip rather than `bs=1`: a byte-at-a-time copy of a megabyte range is
    # thousands of syscalls. `iflag=skip_bytes,count_bytes` keeps the offset exact while the block
    # size stays sane. GNU and BusyBox both have it; BSD `dd` does not, hence the `tail` fallback.
    return string("if dd --version >/dev/null 2>&1; then ",
                  "dd if=", shq(p), " bs=1M iflag=skip_bytes,count_bytes skip=", offset,
                  " count=", len, " 2>/dev/null; else ",
                  "tail -c +", offset + 1, " ", shq(p), " | head -c ", len, "; fi")
end

"Read `len` bytes at `offset` of one blob, wherever the store is."
read_range(s::LocalSource, blob, offset::Integer, len::Integer) =
    open(MemoStore.blob_path(s.root, String(blob)), "r") do io
        seek(io, offset); read(io, len)
    end

function read_range(s::SshSource, blob, offset::Integer, len::Integer)
    script = range_command(s.root, blob, offset, len)
    # The SAME multiplexed connection the metadata sync uses (`ssh_opts`), so a slice costs a round
    # trip rather than a round trip plus a handshake and a key exchange. An empty host runs it here,
    # which is what makes the byte plumbing exercisable without a cluster.
    cmd = isempty(s.host) ? `sh -c $script` : `ssh $(ssh_opts(s.host)) $(s.host) $script`
    out = IOBuffer()
    try
        run(pipeline(cmd; stdout = out, stderr = devnull))
    catch e
        error("reading $(len) bytes of $(blob) from $(s.host) failed: " *
              first(sprint(showerror, e), 160))
    end
    b = take!(out)
    length(b) == len ||
        error("short read from $(s.host): asked $(len) bytes at $(offset), got $(length(b))")
    return b
end

# A chunk fetched from a store the hub cannot see, kept so a second look at the same rows is free.
# Content-addressed, so the cache can never be stale: a blob's name IS its bytes.
_blob_cache_dir() = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                             "kaimonslate", "remote-blobs")

# How big the store actually is, asked where the data is. See the docstring above.
store_size(s::LocalSource) = store_size(s.root)
function store_size(s::SshSource)
    d = joinpath(s.root, "blobs")
    # `du -sk`, not `-sb`: the byte form is GNU-only, and a KiB is finer than this figure is read to.
    ok, out = run_there(s.host,
        "d=" * shq(d) * "; if [ -d \"\$d\" ]; then find \"\$d\" -type f | wc -l; du -sk \"\$d\" | cut -f1; " *
        "else echo 0; echo 0; fi")
    ok || return (; bytes = 0, blobs = 0)
    ns = [tryparse(Int, strip(l)) for l in split(strip(out), '\n') if !isempty(strip(l))]
    length(ns) >= 2 && all(!isnothing, ns[1:2]) || return (; bytes = 0, blobs = 0)
    return (; bytes = ns[2] * 1024, blobs = ns[1])
end

"A local path holding this blob, fetching it once if the store is remote."
blob_file(s::LocalSource, blob, _bytes = 0) = MemoStore.blob_path(s.root, String(blob))
function blob_file(s::SshSource, blob, nbytes::Integer)
    dir = _blob_cache_dir(); mkpath(dir)
    p = joinpath(dir, String(blob))
    isfile(p) && filesize(p) == nbytes && return p
    nbytes > 0 || error("cannot fetch blob $(blob): its size is not recorded")
    tmp = p * ".part.$(getpid())"
    try
        write(tmp, read_range(s, blob, 0, nbytes))
        mv(tmp, p; force = true)          # atomic: a partial fetch never lands under the real name
    catch
        rm(tmp; force = true); rethrow()
    end
    return p
end

"One unit's contribution to a dataset: its index, and the parameters that produced it."
struct DatasetPart
    root::String
    index::Dict{String,Any}
    params::Any
    rows::Int
    bytes::Int
    label::String
    src::Any            # LocalSource | SshSource — where this part's bytes are read from
end
DatasetPart(root, index, params, rows, bytes, label = "") =
    DatasetPart(root, index, params, rows, bytes, label, LocalSource(root))

"""
    Dataset

A sweep's output, addressable and unmoved. Tables concatenate across units into one row space;
arrays stay separate parts, since output of differing shape has no single meaning stacked.

    ds                      # schema, parts, rows, size — no I/O
    ds[1:1000]              # a bounded slice
    ds[1:1000, (:t, :e)]    # …and only these columns
    scan(ds; between = (:e, 3, Inf), where = r -> r.ok, limit = 10_000)
"""
struct Dataset
    kind::Symbol                  # :table | :array
    parts::Vector{DatasetPart}
    columns::Vector{String}
    types::Vector{String}
    starts::Vector{Int}           # cumulative first global row of each part
    whole::Int                    # landed units stored WHOLE (no index) — not slicable
    label::String                 # the sweep it came from, for transfer accounting
    purged::Bool                  # the index survived, the bytes did not
end

function Dataset(kind::Symbol, parts::Vector{DatasetPart}, whole::Integer = 0,
                 label::AbstractString = "", purged::Bool = false)
    cols = isempty(parts) ? String[] : String[String(c) for c in get(parts[1].index, "columns", String[])]
    typs = isempty(parts) ? String[] : String[String(t) for t in get(parts[1].index, "types", String[])]
    starts = Int[]; at = 1
    for p in parts; push!(starts, at); at += p.rows; end
    return Dataset(kind, parts, cols, typs, starts, Int(whole), String(label), purged)
end

# ── Surviving the purge ──────────────────────────────────────────────────────────────────────
# Cluster scratch is deleted on a policy timer — commonly 30 to 90 days — and is not backed up. That
# is where the results are written, and it is the right place for them: it is the only tier with the
# capacity and the bandwidth. What must not die with them is the INDEX, which is kilobytes
# describing terabytes: the schema, the row counts, the chunk offsets and value ranges, and which
# sweep produced them.
#
# So the index is kept HERE, in Slate's data home, which is durable by construction. When the purge
# lands you lose the bytes and nothing else — the dataset can still say what it was, and re-running
# it is one action against a known grid rather than an excavation.
#
# Do not assume reads hold the purge off. Some sites age scratch by access time, but Lustre is
# frequently mounted to skip atime updates precisely to spare its metadata servers, so the window
# has to be treated as running from the WRITE.

_index_dir() = joinpath(SlateHome.data_home(), "datasets")
_index_file(run) = joinpath(_index_dir(), String(run) * ".toml")

"Keep a dataset's index where the scratch purge cannot reach it. Best effort: this is a safety net."
function remember_index!(run::AbstractString, root, parts::Vector{DatasetPart}, kind::Symbol)
    isempty(parts) && return nothing
    try
        mkpath(_index_dir())
        d = Dict{String,Any}("run" => String(run), "root" => String(root),
                             "kind" => String(kind), "saved" => round(Int, time()),
                             "parts" => Any[Dict{String,Any}("index" => p.index,
                                                             "params" => string(p.params),
                                                             "rows" => p.rows, "bytes" => p.bytes)
                                            for p in parts])
        tmp = _index_file(run) * ".tmp"
        open(io -> TOML.print(io, d), tmp, "w")
        mv(tmp, _index_file(run); force = true)
    catch e
        @debug "sweep: could not persist dataset index" run exception = e
    end
    return nothing
end

"The remembered index for a run, or `nothing`. What is left after the store is purged."
function recall_index(run::AbstractString)
    p = _index_file(run)
    isfile(p) || return nothing
    return try; TOML.parsefile(p); catch; nothing; end
end

"Has this part's data actually survived? A remembered index can outlive the bytes it describes."
function part_present(p::DatasetPart)
    blobs = String[]
    if String(get(p.index, "kind", "")) == "array"
        push!(blobs, String(p.index["blob"]))
    else
        cs = get(p.index, "chunks", Any[])
        isempty(cs) || push!(blobs, String(first(cs)["blob"]))   # one probe, not thousands
    end
    isempty(blobs) && return true
    return all(b -> _blob_there(p.src, b), blobs)
end

_blob_there(s::LocalSource, b) = MemoStore.has_blob(s.root, String(b))
function _blob_there(s::SshSource, b)
    ok, out = run_there(s.host, "test -f " * shq(MemoStore.blob_path(s.root, String(b))) * " && echo y")
    return ok && occursin("y", out)
end

# Assembled from the shard manifests: one part per unit that has landed WITH a dataset index, in
# grid order. A partial sweep gives a partial dataset rather than an error — the same property that
# lets the rest of the fabric be watched while it runs.
function _dataset_of(root, params, keys, label = "", src = LocalSource(root))
    parts = DatasetPart[]
    kind = :table
    whole = 0
    for (prm, k) in zip(params, keys)
        m = MemoStore.read_manifest(root, k)
        m === nothing && continue
        String(get(m, "status", "")) == "ok" || continue
        idx = get(m, "dataset", nothing)
        if !(idx isa AbstractDict)
            whole += 1          # ran before `data=lazy`, or returned something unaddressable
            continue
        end
        d = Dict{String,Any}(String(kk) => vv for (kk, vv) in idx)
        kind = String(d["kind"]) == "array" ? :array : :table
        push!(parts, DatasetPart(String(root), d, prm, Int(get(d, "rows", 0)),
                                 Int(get(d, "bytes", 0)), String(label), src))
    end
    # The store had nothing to say. Either this sweep never ran, or its scratch has been purged and
    # the manifests went with it — and the difference matters, because in the second case we still
    # know exactly what the dataset was.
    if isempty(parts) && whole == 0 && !isempty(label)
        remembered = recall_index(label)
        if remembered !== nothing
            kind = String(get(remembered, "kind", "table")) == "array" ? :array : :table
            for pd in get(remembered, "parts", Any[])
                pd isa AbstractDict || continue
                idx = Dict{String,Any}(String(k) => v for (k, v) in get(pd, "index", Dict()))
                push!(parts, DatasetPart(String(root), idx, get(pd, "params", ""),
                                         Int(get(pd, "rows", 0)), Int(get(pd, "bytes", 0)),
                                         String(label), src))
            end
            # One probe, not one per chunk: if the first blob is gone the store was purged.
            gone = !isempty(parts) && !part_present(parts[1])
            return Dataset(kind, parts, whole, label, gone)
        end
    end
    remember_index!(label, root, parts, kind)
    return Dataset(kind, parts, whole, label)
end

Base.length(ds::Dataset) = isempty(ds.parts) ? 0 : ds.starts[end] + ds.parts[end].rows - 1
nparts(ds::Dataset) = length(ds.parts)
databytes(ds::Dataset) = sum(p -> p.bytes, ds.parts; init = 0)

function Base.show(io::IO, ::MIME"text/plain", ds::Dataset)
    n = length(ds)
    println(io, "Dataset — ", nparts(ds), " part", nparts(ds) == 1 ? "" : "s", ", ",
            ds.kind === :table ? "$(n) rows" : "$(n) elements", ", ", _bytes(databytes(ds)))
    if ds.kind === :table
        for (c, t) in zip(ds.columns, ds.types)
            println(io, "   ", rpad(c, 18), t)
        end
        println(io, "   ds[1:1000] for rows · scan(ds; …) to filter · query_cost(ds) to price it")
    else
        d = get(ds.parts[1].index, "dims", Int[])
        println(io, "   each part ", join(d, "×"), " ", String(get(ds.parts[1].index, "eltype", "")))
        println(io, "   ds[k] for part k · part[i…] to slice it")
    end
    # Units that finished before the cell asked for addressable storage still hold their results;
    # they just cannot be sliced. Saying so beats a dataset that is quietly missing most of itself.
    ds.purged && println(io, "   ⚠ the data is gone — this store was purged. The index is kept, so ",
                         "the schema and counts above are what it HELD; re-run the sweep to rebuild it.")
    ds.whole == 0 || println(io, "   ⚠ ", ds.whole, " finished unit", ds.whole == 1 ? "" : "s",
                             " stored whole and not in this view — reset the sweep to re-store")
    # What this session has actually pulled out of it, against what it holds. The ratio is the
    # number the whole design is for, so it belongs where the dataset describes itself.
    got = transferred(ds.label)
    tot = databytes(ds)
    println(io, "   read so far: ", got == 0 ? "nothing" : _bytes(got),
            (got > 0 && tot > 0) ? " of " * _bytes(tot) *
                                   " (" * string(round(100 * got / tot; digits = 2)) * "%)" : "")
    return nothing
end
Base.show(io::IO, ds::Dataset) =
    print(io, "Dataset(", ds.kind, ", ", nparts(ds), " parts, ", length(ds), ", ",
          _bytes(databytes(ds)), ")")

# Global rows → the parts that hold them, with each part's LOCAL range. Pure index arithmetic.
function _ds_span(ds::Dataset, rows::AbstractUnitRange)
    out = Tuple{Int,UnitRange{Int}}[]
    for (i, p) in enumerate(ds.parts)
        lo = ds.starts[i]; hi = lo + p.rows - 1
        (hi < first(rows) || lo > last(rows)) && continue
        push!(out, (i, (max(first(rows), lo) - lo + 1):(min(last(rows), hi) - lo + 1)))
    end
    return out
end

# How many rows one call may bring back. A slice is meant to be a look at the data, not a way to
# spell "all of it" — the cap is what keeps that true for a dataset whose size is unknown at the
# call site. Raise it deliberately per call.
const DATASET_ROW_CAP = 1_000_000

"""
    ds[rows]            -> NamedTuple of columns
    ds[rows, columns]   -> …only those columns

Read a bounded row range. Only the chunks covering `rows` are opened, and only the columns named.
"""
Base.getindex(ds::Dataset, rows::AbstractUnitRange, cols = nothing) = load(ds, rows; select = cols)

"""
    load(ds, rows; select = nothing, max_rows = DATASET_ROW_CAP) -> NamedTuple of columns

The read behind `ds[rows]`, with the cap exposed. Raising `max_rows` is how you ask for more than a
look — deliberately, at one call site, with the number written down.
"""
function load(ds::Dataset, rows::AbstractUnitRange; select = nothing,
              max_rows::Integer = DATASET_ROW_CAP)
    ds.purged && error("this dataset's data has been purged from the store — the index survived, " *
                       "so the schema and counts are still readable, but the bytes are gone. " *
                       "Re-run the sweep to rebuild it.")
    ds.kind === :table ||
        error("this dataset holds arrays, not rows — `ds[k]` for part k, then slice that part")
    n = length(ds)
    (first(rows) >= 1 && last(rows) <= n) ||
        throw(BoundsError("rows $(rows) outside 1:$(n)"))
    length(rows) <= max_rows ||
        error("$(length(rows)) rows is over the $(max_rows)-row slice cap — narrow the range, " *
              "use `scan(ds; limit = …)` to stream a filtered subset, or raise it deliberately " *
              "with `Sweep.load(ds, rows; max_rows = …)`")
    cols = select
    acc = nothing
    bytes = 0; opened = 0; t0 = time()
    for (i, local_rows) in _ds_span(ds, rows)
        p = ds.parts[i]
        # Charged BEFORE the read, off the index: these are the chunks the slice resolves to, so
        # the figure is what the query costs whether the bytes come off a mmap or a wire.
        for (pos, _, _, _) in SlateTask.table_chunks(p.index, local_rows)
            opened += 1; bytes += Int(p.index["chunks"][pos]["bytes"])
        end
        part = SlateTask.dataset_rows(p.root, p.index, local_rows; select = cols,
                                      blobpath = (h, n) -> blob_file(p.src, h, n))
        acc = acc === nothing ? map(collect, part) :
              NamedTuple{keys(acc)}(Tuple(append!(acc[k], part[k]) for k in keys(acc)))
    end
    _record!(ds.label, isempty(ds.parts) ? "" : ds.parts[1].root, :rows, bytes, opened,
             (time() - t0) * 1000)
    return acc === nothing ? NamedTuple() : acc
end
Base.getindex(ds::Dataset, rows::AbstractUnitRange, col::Symbol) = getindex(ds, rows, (col,))[col]

"Part `k` of an array dataset — a handle, not its contents."
function Base.getindex(ds::Dataset, k::Integer)
    ds.kind === :array ||
        error("this dataset is a table — `ds[rows]` reads rows; `ds.parts[$k]` is the raw part")
    return ds.parts[k]
end

Base.show(io::IO, p::DatasetPart) =
    print(io, "DatasetPart(", join(get(p.index, "dims", Int[]), "×"), " ",
          String(get(p.index, "eltype", "")), ", ", _bytes(p.bytes), ")")

"""
    part[i]      -> elements i of this part, as stored (linear order)

Reads exactly that range: the mapping starts at the range's first byte, so nothing before or after
it is touched.
"""
# A read that fails because the bytes are gone should say so. The alternative is a `SystemError` on
# a path, or a short read from the far side — both of which read as a bug in Slate rather than as
# the store having been purged out from under it.
function _explain_missing(p::DatasetPart, e)
    part_present(p) && rethrow(e)
    error("this part's data is no longer in the store — scratch is purged on a timer and is not " *
          "backed up. The index is kept, so the schema and counts are still readable; re-run the " *
          "sweep to rebuild the data.")
end

function Base.getindex(p::DatasetPart, i::AbstractUnitRange)
    t0 = time()
    v = try
        if p.src isa LocalSource
            # Local: mmap the window, so the pages outside it are never faulted in.
            SlateTask.dataset_elements(p.root, p.index, i)
        else
            # Remote: the same window as an exact byte range, reinterpreted on arrival. An array's
            # layout is what makes this a single request rather than a search.
            blob, off, nb, _ = SlateTask.array_range(p.index, i)
            T = Core.eval(Main, Meta.parse(String(p.index["eltype"])))
            collect(reinterpret(T, read_range(p.src, blob, off, nb)))
        end
    catch e
        _explain_missing(p, e)
    end
    _record!(p.label, p.root, :elements, length(i) * Int(p.index["elsize"]), 1,
             (time() - t0) * 1000)
    return v
end
Base.getindex(p::DatasetPart, i::Integer) = p[i:i][1]
Base.length(p::DatasetPart) = p.rows

"""
    query_cost(ds; between = nothing) -> NamedTuple

What a read WOULD cost, before making it: the stored pieces it must open, the bytes they hold, and
that as a share of the dataset. Answered from the index alone — the same question, against the same
numbers, that the reader asks before it opens anything.

`between = (:col, lo, hi)` prices a range predicate; without it, the whole dataset.
"""
function query_cost(ds::Dataset; between = nothing)
    total = 0; kept = 0; bytes = 0
    for p in ds.parts
        cs = get(p.index, "chunks", Any[])
        total += length(cs)
        keep = between === nothing ? (1:length(cs)) :
               SlateTask.prune_chunks(p.index, String(between[1]),
                                      Float64(between[2]), Float64(between[3]))
        for i in keep; kept += 1; bytes += Int(cs[i]["bytes"]); end
    end
    tot = databytes(ds)
    return (; chunks = kept, of_chunks = total, bytes, pretty = _bytes(bytes),
              fraction = tot > 0 ? round(bytes / tot; digits = 4) : 0.0,
              percent = tot > 0 ? round(100 * bytes / tot; digits = 2) : 0.0)
end

"""
    scan(ds; select, between, where, limit) -> NamedTuple of columns

Stream a dataset and keep the rows that match, stopping at `limit`.

`between = (:col, lo, hi)` is pushed DOWN to the index: chunks whose recorded range for that column
cannot contain a match are never opened. `where` is an ordinary predicate over a row NamedTuple,
applied to what survives — it cannot be pushed down, so it costs a read of the chunks that reach it.
"""
function scan(ds::Dataset; select = nothing, between = nothing, where = nothing,
              limit::Integer = 10_000)
    ds.kind === :table || error("scan works on table datasets")
    want = select === nothing ? ds.columns : String[String(s) for s in select]
    # A `where` needs every column it might look at, so a projection is only safe alongside one
    # when the caller has said which columns matter.
    readcols = where === nothing ? want : ds.columns
    keep = [Any[] for _ in want]
    got = 0
    bytes = 0; opened = 0; t0 = time()
    for p in ds.parts
        chunks = between === nothing ? nothing :
                 Set(SlateTask.prune_chunks(p.index, String(between[1]),
                                            Float64(between[2]), Float64(between[3])))
        at = 1
        for (pos, c) in enumerate(get(p.index, "chunks", Any[]))
            nrows = Int(c["rows"])
            if chunks === nothing || pos in chunks
                opened += 1; bytes += Int(c["bytes"])
                blk = SlateTask.dataset_rows(p.root, p.index, at:(at + nrows - 1);
                                             select = readcols,
                                             blobpath = (h, n) -> blob_file(p.src, h, n))
                syms = keys(blk)
                for r in 1:nrows
                    row = NamedTuple{syms}(Tuple(blk[s][r] for s in syms))
                    between === nothing || let v = row[Symbol(between[1])]
                        (v >= between[2] && v <= between[3]) || continue
                    end
                    where === nothing || Base.invokelatest(where, row) || continue
                    for (j, nm) in enumerate(want); push!(keep[j], row[Symbol(nm)]); end
                    got += 1
                    got >= limit && @goto done
                end
            end
            at += nrows
        end
    end
    @label done
    _record!(ds.label, isempty(ds.parts) ? "" : ds.parts[1].root, :rows, bytes, opened,
             (time() - t0) * 1000)
    return NamedTuple{Tuple(Symbol.(want))}(Tuple(isempty(k) ? k : identity.(k) for k in keep))
end

_bytes(n::Integer) = n < 1024 ? "$(n) B" :
                     n < 1024^2 ? "$(round(n / 1024; digits = 1)) KB" :
                     n < 1024^3 ? "$(round(n / 1024^2; digits = 1)) MB" :
                     "$(round(n / 1024^3; digits = 2)) GB"

# A grouped summary comes back as a NamedTuple, so it reads the way it was written: a unit that
# reported `(; loss, acc)` is asked for `row.summary.loss`.
function _summary_of(m)
    s = get(m, "summary", nothing)
    s isa AbstractDict || return s
    ks = Tuple(Symbol.(collect(keys(s))))
    return NamedTuple{ks}(Tuple(collect(values(s))))
end

function _ref(root, m, src = LocalSource(root))
    bs = get(m, "bindings", Any[])
    isempty(bs) && return nothing
    b = bs[1]
    b isa AbstractDict || return nothing
    sh = get(m, "shape", Dict{String,Any}())
    return ShardRef(String(root), Dict{String,Any}(String(k) => v for (k, v) in b),
                    Vector{Int}(get(sh, "dims", Int[])),
                    String(get(sh, "eltype", "")), String(get(sh, "type", "")),
                    Int(get(b, "bytes", 0)), src)
end

# Manifest-only. Every field here is answered by a small TOML read, so watching a sweep — the
# counters, the tiles, the chart — costs the same whether a unit returned a number or a gigabyte.
# `value` is a handle; `summary` is the small number a unit recorded for charting.
function _rows(root, params, keys, src = LocalSource(root))
    rows = NamedTuple[]
    for (prm, k) in zip(params, keys)
        m = MemoStore.read_manifest(root, k)
        if m === nothing
            push!(rows, (; params = prm, status = "", value = nothing, summary = nothing,
                           artifacts = ArtifactRef[], ran_on = "", ms = 0.0, bytes = 0))
            continue
        end
        st = String(get(m, "status", ""))
        val = st == "ok" ? _ref(root, m, src) : get(m, "error", nothing)
        push!(rows, (; params = prm, status = st, value = val,
                       summary = _summary_of(m),
                       artifacts = _arts(root, m, src),
                       ran_on = String(get(m, "ran_on", "")),
                       ms = Float64(get(m, "ms", 0.0)),
                       bytes = st == "ok" ? Int(get(get(m, "shape", Dict()), "bytes", 0)) : 0))
    end
    return rows
end

"""
    refresh!(r) -> r

Re-read the store and the scheduler. This is what a sweep cell does when it is re-run, and what a
progress display calls on a timer.
"""
function refresh!(r::ShardedResult)
    # Re-read the STORE, which for a cluster means catching the mirror up first — everything below
    # reads a local path, and without this it would faithfully re-report what the hub already knew.
    sync_in!(r.target)
    root = store_root(r.target)
    l = launcher_for(r.target)
    r.plan = BatchSweep.plan(root, r.run; launcher = l)
    r.rows = _rows(root, r.params, r.keys, source_of(r.target))
    r.telemetry = BatchSweep.telemetry(root, r.run; launcher = l, plan = r.plan)
    return r
end

"""
    load(r; max_bytes = 512 * 1024^2, limit = 0) -> Vector

Materialize the successful units' values. This is the only call that reads result data in bulk, and
it refuses above `max_bytes` rather than doing it quietly — a sweep's whole point is that its output
can be larger than the machine reading it. `r.bytes` is the total; `limit` takes the first N units.

    r.summaries          # what to reach for: manifest-resident, always cheap
    r[3][]               # one unit
    Sweep.load(r; limit = 8)
"""
function load(r::ShardedResult; max_bytes::Integer = 512 * 1024^2, limit::Integer = 0)
    ok = [row for row in getfield(r, :rows) if row.status == "ok"]
    limit > 0 && (ok = ok[1:min(limit, length(ok))])
    total = sum(row.bytes for row in ok; init = 0)
    total > max_bytes && error(
        "Sweep.load: $(length(ok)) units hold $(_bytes(total)), over the $(_bytes(max_bytes)) " *
        "limit. Use `r.summaries` for analysis, `r[i][]` for one unit, or pass `limit=` / " *
        "`max_bytes=` to ask for this deliberately.")
    return [row.value isa ShardRef ? row.value[] : row.value for row in ok]
end

"Clear the failed shards so the next run of the sweep cell retries exactly those."
function retry_failed!(r::ShardedResult)
    root = store_root(r.target)
    failed = [k for k in r.keys
              if (m = MemoStore.read_manifest(root, k);
                  m !== nothing && String(get(m, "status", "")) == "error")]
    return forget_results!(r.target, failed)
end

"""
    cancel!(r) -> r

Stop the sweep at your request: kill what is running and record the stop durably, so re-running the
cell (or reopening the notebook) does not quietly start it again. Finished units are kept.
"""
function cancel!(r::ShardedResult)
    BatchSweep.cancel!(store_root(r.target), r.run, launcher_for(r.target))
    # The marker is the durable half of "stop": a fresh hub reads it and does not resubmit. It has
    # to reach the store to do that, and the same goes for `resume!` lifting it.
    sync_out!(r.target; dirs = ("jobs",))
    return refresh!(r)
end

"""
    resume!(r) -> r

Undo a `cancel!`. The next run submits only what is still missing.
"""
function resume!(r::ShardedResult)
    BatchSweep.resume!(store_root(r.target), r.run)
    sync_out!(r.target; dirs = ("jobs",))
    return refresh!(r)
end

"Drop every result for this sweep, so the next run starts cold."
function reset!(r::ShardedResult)
    root = store_root(r.target)
    n = forget_results!(r.target, r.keys)
    BatchSweep.clear_attempts!(root, r.run)
    BatchSweep.resume!(root, r.run)   # a reset sweep is not still cancelled
    sync_out!(r.target; dirs = ("jobs",))
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

# WHEN it finishes, not just how much longer. "~3h12m left" is a number you then have to add to the
# clock; "done ~17:45" is one you can act on — go to lunch, come back after the meeting, leave it
# overnight. The date comes along once the answer is not today, because "done ~09:20" on a run that
# lands tomorrow morning is worse than useless.
function _eta_clock(eta_s::Real; now = Dates.now())
    eta_s < 0 && return ""
    t = now + Dates.Millisecond(round(Int, eta_s * 1000))
    same_day = Dates.Date(t) == Dates.Date(now)
    return same_day ? Dates.format(t, "HH:MM") :
           (Dates.Date(t) - Dates.Date(now)) <= Dates.Day(6) ? Dates.format(t, "e HH:MM") :
           Dates.format(t, "d u HH:MM")
end

# ── Live status over the JS channel ──────────────────────────────────────────────────────────
# A monitor that re-ran the cell to advance would re-run every downstream cell with it, which for a
# sweep of thousands of units is far more work than the sweep. Instead the rendered card polls a
# `slateCall` channel and patches its own DOM: the browser animates, and the notebook's dependency
# graph is untouched until the VALUE actually changes.
#
# The handler re-reads the store on every call rather than closing over a snapshot, so it stays
# correct across a worker restart and reports what is actually on disk.

"The channel a card polls. Keyed by the RUN, so a pilot and the full sweep do not share a card."
status_channel(run::AbstractString) = "sweep:" * String(run)

"The channel the card's buttons call. Separate from status so a poll can never be a mutation."
action_channel(run::AbstractString) = "sweep:" * String(run) * ":do"

"""
    handle_action(target, run, params, keys, action; plot = nothing) -> payload

Apply a control the card offers, then report the resulting state so the button press and the
refresh are one round trip.

`cancel` and `reset` are destructive in different degrees and are kept apart deliberately: cancel
STOPS a sweep and keeps every finished unit, so resuming costs only what is left; reset throws the
results away.
"""
function handle_action(target::SweepTarget, run::AbstractString, params, keys,
                       action::AbstractString; plot = nothing, notify = nothing)
    sync_in!(target)
    root = store_root(target)
    l = launcher_for(target)
    # Not a mutation: the card reporting, once, that the work is over. A sweep finishes minutes or
    # hours after the cell that started it returned, so without this the notebook's own view of the
    # results stays frozen at "nothing has landed yet" until someone re-runs a cell by hand — which
    # is exactly the manual bookkeeping this fabric exists to remove.
    if action == "settled"
        notify === nothing || notify()
        return status_payload(target, run, params, keys; plot, advance = false)
    end
    if action == "submit"
        BatchSweep.arm!(root, run)
    elseif action == "cancel"
        BatchSweep.cancel!(root, run, l)
        BatchSweep.disarm!(root, run)
    elseif action == "resume"
        BatchSweep.resume!(root, run)
        BatchSweep.arm!(root, run)
    elseif action == "retry"
        # Same reason as reset: dropping a failed unit's manifest only in the mirror leaves it on
        # the cluster, and the next sync brings the failure straight back.
        failed = [k for k in keys
                  if (m = MemoStore.read_manifest(root, k);
                      m !== nothing && String(get(m, "status", "")) == "error")]
        forget_results!(target, failed)
    elseif action == "reset"
        # Kill anything live FIRST. `clear_attempts!` forgets the submission records, and with them
        # the job names needed to reach the scheduler — reversing these two would leave orphaned jobs
        # writing results into a store that had just been emptied.
        BatchSweep.cancel!(root, run, l)
        BatchSweep.clear_attempts!(root, run)
        forget_results!(target, keys)
        # Cleared and READY, not stopped: drop the cancellation `cancel!` just wrote, and leave the
        # sweep unarmed so submitting it again is a separate decision.
        BatchSweep.resume!(root, run)
        BatchSweep.disarm!(root, run)
    else
        error("unknown sweep action: $(action)")
    end
    sync_out!(target)   # arming, cancellation and cleared attempts are all markers in the store
    return status_payload(target, run, params, keys; plot)
end

# Compact enough to poll on a timer: counts and rates, plus a per-unit status string of one
# character each. At a few thousand units that string is a few KB, which is cheap next to sending
# structured rows for every unit.
function status_payload(target::SweepTarget, run::AbstractString, params, keys;
                        plot = nothing, advance::Bool = true)
    sync_in!(target)
    root = store_root(target)
    l = launcher_for(target)
    # The poll RECONCILES, it does not merely observe. The probe wave releases one chunk and waits
    # for it to report; if only the cell could reconcile, a sweep would sit at "10 / 60, running"
    # until the author re-ran it by hand, once per wave. Reconciling is idempotent and submits
    # nothing that is already live, so polling it is safe — and the breaker still stops a sweep
    # whose units are failing, which is the case the waves exist for.
    # …and it only submits for a sweep that has been ARMED, so a card left open on a sweep nobody
    # asked to run cannot start it.
    armed = BatchSweep.is_armed(root, run)
    p = advance ? reconcile_and_sync!(target, run, l; submit = armed) :
                  BatchSweep.plan(root, run; launcher = l)
    t = BatchSweep.telemetry(root, run; launcher = l, plan = p)
    _ds = display_state(p, armed)
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

    out = Dict{String,Any}(
        "state" => String(_ds), "label" => _state_label(_ds),
        "total" => p.shards_total, "done" => p.shards_done,
        "ok" => p.shards_ok, "failed" => p.shards_failed, "missing" => p.shards_missing,
        "frac" => BatchSweep.fraction(p),
        "rate" => t.rate_per_s, "eta" => t.eta_s, "idle" => t.idle_s,
        "stuck" => BatchSweep.stalled_for(t), "blocked" => p.blocked,
        "settled" => BatchSweep.is_settled(p), "tiles" => tiles,
        "color" => get(_STATE_COLOR, _ds, "var(--dim,#6a7090)"),
        # The controls that apply RIGHT NOW, so the card's buttons track its state instead of
        # freezing at whatever was true when the cell last ran.
        "actions" => [Any[a, l] for (a, l) in action_list(p, armed)],
        # Why it stopped. Carried on every poll because a sweep that blocks WHILE being watched
        # must explain itself then, not only if someone happens to re-run the cell afterwards.
        "why" => _why_html(p))
    # The data line grows as units land, so it rides the poll too. Off the indices, so a sweep
    # writing terabytes still costs manifest reads to watch.
    ds = _dataset_of(root, params, keys, run, source_of(target))
    out["data"] = _data_html(ds)
    # …and the same two figures as NUMBERS, for the notebook-level pill. The card can render HTML;
    # the topbar panel aggregates across sweeps and needs to add them up.
    if nparts(ds) > 0
        out["dsbytes"] = databytes(ds)
        out["dsread"] = transferred(run)
        out["dskind"] = String(ds.kind)
    end

    # The chart rides the SAME poll as the counters, so a filling plot costs no extra round trip and
    # cannot disagree with the numbers beside it.
    # The failure list rides it too, for the same reason as `why` — and off the same rows the chart
    # already needs, so watching a failing sweep costs no extra manifest reads.
    if plot !== false || p.shards_failed > 0
        rows = _rows(root, params, keys, source_of(target))
        if plot !== false
            opt, err = _plot_option(plot, rows)
            opt === nothing || (out["chart"] = opt)
            isempty(err) || (out["charterr"] = err)
        end
        out["fails"] = _fails_html(rows)
    end
    return out
end

# ── The chart you get without asking ─────────────────────────────────────────────────────────
# A unit that returns a NUMBER over a single varying numeric axis has exactly one sensible plot,
# and making someone write it out is the ad-hoc wiring this fabric exists to remove.
#
# Anything less clear-cut draws nothing rather than guessing. A default chart that picks the wrong
# axis, or silently collapses one of two, is worse than no chart at all: it looks authoritative.
# `plot = false` turns it off; `plot = f` replaces it.

# One tile per unit stays flat however large a sweep gets, but a line does not — and neither does
# the payload carrying it. Past this many units the grid IS the right view.
const _AUTO_PLOT_MAX = 2000

# The single grid axis that is numeric AND actually varies. Two varying axes mean a line chart would
# silently project one of them away, so the default declines and the author says what they meant.
function _auto_axis(rows)
    isempty(rows) && return nothing
    p1 = rows[1].params
    p1 isa NamedTuple || return nothing
    found = Symbol[]
    for k in keys(p1)
        vals = Any[]
        for r in rows
            hasproperty(r.params, k) || return nothing
            push!(vals, getproperty(r.params, k))
        end
        all(v -> v isa Real, vals) || continue
        length(unique(vals)) > 1 && push!(found, k)
    end
    return length(found) == 1 ? found[1] : nothing
end

function _auto_plot(rows)
    (isempty(rows) || length(rows) > _AUTO_PLOT_MAX) && return nothing
    ax = _auto_axis(rows)
    ax === nothing && return nothing
    landed = [r for r in rows if r.status == "ok"]
    isempty(landed) && return nothing
    # A bare number plots as itself. A grouped summary plots only when ONE of its fields is numeric;
    # with several, which one is the author's business.
    field = nothing
    if !all(r -> r.summary isa Real, landed)
        s1 = landed[1].summary
        s1 isa NamedTuple || return nothing
        nums = [k for k in keys(s1) if getproperty(s1, k) isa Real]
        length(nums) == 1 || return nothing
        field = nums[1]
        all(r -> r.summary isa NamedTuple && hasproperty(r.summary, field) &&
                 getproperty(r.summary, field) isa Real, landed) || return nothing
    end
    yof(r) = r.status != "ok" ? nothing :
             field === nothing ? r.summary : getproperty(r.summary, field)
    # `nothing` for a unit that has not reported: the axis is then fixed from the first frame and the
    # line breaks at the real gaps, so the picture only gains detail instead of changing shape.
    return Dict{String,Any}(
        "backgroundColor" => "transparent", "animation" => false,
        # `containLabel` rather than fixed margins: this chart is drawn for values nobody has seen
        # yet, so no hardcoded left inset can be right for both `0.5` and `200,000` — the wide one
        # gets its first digit clipped. Axis NAMES sit in the middle of their axis for the same
        # reason: at the end, a name runs off the edge of the plot area it labels.
        "grid"    => Dict("left" => 10, "right" => 18, "top" => 24, "bottom" => 6,
                          "containLabel" => true),
        "tooltip" => Dict("trigger" => "axis"),
        "xAxis"   => Dict("type" => "value", "name" => String(ax),
                          "nameLocation" => "middle", "nameGap" => 26),
        "yAxis"   => Dict("type" => "value", "name" => field === nothing ? "" : String(field),
                          "nameLocation" => "middle", "nameGap" => 52),
        "series"  => [Dict("type" => "line", "showSymbol" => true, "symbolSize" => 4,
                           "connectNulls" => false,
                           "data" => [[getproperty(r.params, ax), yof(r)] for r in rows])])
end

# The author's plot function, applied to EVERY unit in grid order — landed or not, each row
# carrying its `status`. Passing only the successful ones would hide where the holes are, and a
# chart drawn straight through them invents shape the data does not support: a sweep's chunks come
# back out of order, so a line through "whatever has landed" swings between distant points and then
# rewrites itself as the gaps fill. With the full grid an author can plot `[x, nothing]` for a unit
# that has not reported, which keeps the axis fixed from the first frame and breaks the line at the
# real gaps — so the picture only ever gains detail instead of changing shape.
#
# A plot that throws must say so on the card: a silently blank chart during a long run is exactly
# the "is it working?" ambiguity the fabric exists to remove, and it would be blamed on the sweep.
function _plot_option(plot, rows)
    plot === false && return nothing, ""       # explicitly no chart
    plot === nothing && return _auto_plot(rows), ""
    try
        v = Base.invokelatest(plot, rows)
        v === nothing && return nothing, ""
        # Duck-typed rather than depending on the host's `EChart`: this module is loaded into the
        # worker AND the engine, and it should not care which one owns that struct.
        opt = hasproperty(v, :option) ? getproperty(v, :option) : v
        opt isa AbstractDict || return nothing,
            "plot returned a $(typeof(v)); it must return an echart(…) or an option Dict"
        return opt, ""
    catch e
        return nothing, sprint(showerror, e)
    end
end

# ── HTML rendering ───────────────────────────────────────────────────────────────────────────
# The notebook's view of a sweep. The text form below stays as the fallback for a standalone
# `julia notebook.jl` run, the REPL, and static export, where there is no DOM to write into.
#
# Styles are inline and theme variables carry fallbacks, so this renders correctly in an exported
# page that never loaded the notebook's stylesheet.

_esc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

# A JSON writer for the chart option, in ~20 lines, rather than a JSON dependency. This module is
# loaded into the WORKER, whose project is the notebook's and may not have JSON at all — and an
# ECharts option is only ever numbers, strings, bools, arrays and dicts, which is the whole grammar
# below. The poll payload is encoded by the host's own transport; this is for the option baked into
# the card at render time, so a chart is there before the first round trip and survives export.
_json(io, ::Nothing) = print(io, "null")
_json(io, x::Bool) = print(io, x ? "true" : "false")
_json(io, x::Integer) = print(io, x)
_json(io, x::Real) = print(io, isfinite(x) ? string(Float64(x)) : "null")
_json(io, x::Symbol) = _json(io, String(x))
function _json(io, s::AbstractString)
    print(io, '"')
    for c in s
        c == '"'  ? print(io, "\\\"") : c == '\\' ? print(io, "\\\\") :
        c == '\n' ? print(io, "\\n")  : c == '\r' ? print(io, "\\r")  :
        c == '\t' ? print(io, "\\t")  :
        # `</script>` inside a string would close the tag the card is written into.
        c == '<'  ? print(io, "\\u003c") :
        c < ' '   ? print(io, "\\u", lpad(string(UInt16(c); base = 16), 4, '0')) : print(io, c)
    end
    print(io, '"')
end
function _json(io, v::AbstractVector)
    print(io, '[')
    for (i, x) in enumerate(v); i > 1 && print(io, ','); _json(io, x); end
    print(io, ']')
end
function _json(io, d::AbstractDict)
    print(io, '{')
    for (i, (k, v)) in enumerate(d)
        i > 1 && print(io, ',')
        _json(io, string(k)); print(io, ':'); _json(io, v)
    end
    print(io, '}')
end
_json(io, t::Tuple) = _json(io, collect(t))
_json(io, x) = _json(io, string(x))     # anything else describes itself; never breaks the card
_json(x) = sprint(_json, x)

# Slate's own palette (notebook.css `:root`), literal rather than `var(--green)` because these are
# also written into the poll payload and set from JavaScript, where a CSS variable would not resolve.
const _STATE_COLOR = Dict(
    :succeeded => "#56d364", :partial   => "#ffd700", :blocked => "#e57575",
    :exhausted => "#e57575", :cancelled => "#6a7090", :running => "#569cd6",
    :pending   => "#6a7090", :ready     => "#4ec9b0")

# The three ways of stopping short read differently on purpose: one is the work's fault, one is
# yours, and one is the resources'.
_state_label(s) = s === :succeeded ? "complete" :
                  s === :partial   ? "finished, with failures" :
                  s === :blocked   ? "stopped — the work is failing" :
                  s === :cancelled ? "stopped at your request" :
                  s === :exhausted ? "gave up — units never landed" :
                  s === :running   ? "running" :
                  s === :ready     ? "ready — nothing submitted" : "not started"

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

# Where this sweep runs and under what limits. Shown on the card because the settings are half of
# what you need in order to read a stalled or killed run: "3 of 4, gave up" means one thing at a
# 20-second walltime and another at two hours.
function _target_line(t::SlurmTarget)
    bits = String[isempty(t.host) ? "slurm" : t.host]
    r = t.resources
    for (k, fmt) in ((:partition, identity), (:cpus, v -> "$(v) cpu"), (:gpus, v -> "$(v) gpu"),
                     (:mem, identity), (:walltime, identity), (:nodes, v -> "$(v) nodes"))
        v = get(r, k, nothing)
        v === nothing || push!(bits, String(fmt(v)))
    end
    isempty(t.account) || push!(bits, "acct " * t.account)
    push!(bits, "$(t.chunk)/job")
    return join(bits, " · ")
end
_target_line(t::LocalTarget) = "local · $(t.chunk)/job"

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

# For a `data=lazy` sweep: how much output is sitting out there, and how much of it this session has
# actually pulled in. "" for an ordinary sweep, where the result came back whole and there is
# nothing to distinguish. Built from the indices, so showing it reads none of the data.
function _data_html(ds::Dataset)
    nparts(ds) == 0 && return ""
    tot = databytes(ds)
    got = transferred(ds.label)
    x = transfers(; label = ds.label)
    bits = [string(nparts(ds), " part", nparts(ds) == 1 ? "" : "s"),
            ds.kind === :table ? string(length(ds), " rows") : string(length(ds), " elements"),
            _bytes(tot) * " stored"]
    push!(bits, got == 0 ? "nothing read yet" :
                string(_bytes(got), " read",
                       tot > 0 ? " (" * string(round(100 * got / tot; digits = 2)) * "%)" : "",
                       " · ", x.rate))
    return string("<div style='font-size:11px;color:var(--val,#4ec9b0);opacity:.85;margin-top:4px;",
                  "font-family:ui-monospace,monospace'>", _esc(join(bits, " · ")), "</div>")
end

# Why a sweep stopped, and what to do about it. The three ways of stopping short need different
# things, so they read differently. "" while the sweep is still going.
function _why_html(p::BatchSweep.Plan)
    box(color, body) = string(
        "<div style='margin-top:8px;padding:8px;border-radius:6px;background:color-mix(in srgb, ",
        color, " 12%, transparent);font-size:12px;color:", color, "'>", body, "</div>")
    p.state === :blocked && return box("var(--red,#e57575)",
        string(_esc(p.blocked), "<br><span style='opacity:.8'>Nothing further will be submitted. ",
               "Fix the body, then <code>Sweep.reset!</code>.</span>"))
    p.state === :exhausted && return box("var(--red,#e57575)",
        string("Attempted ", BatchSweep.MAX_ATTEMPTS, "× without landing, so these units are ",
               "outrunning their resources rather than erroring.<br><span style='opacity:.8'>",
               "Raise the walltime or memory, then <code>Sweep.reset!</code>.</span>"))
    p.state === :cancelled && return string(
        "<div style='margin-top:8px;padding:8px;border-radius:6px;background:color-mix(in srgb, ",
        "var(--dim,#6a7090) 12%, transparent);font-size:12px;opacity:.85'>",
        "Stopped at your request. ", p.shards_done, " finished units are kept — ",
        "<code>Sweep.resume!</code> continues with the remaining ", p.shards_missing, ".</div>")
    return ""
end

# The failed units, collapsed. The parameters matter more than the traceback at a glance, so they
# lead: the question is almost always "which corner of the grid breaks?" rather than "how?".
const _FAILS_SHOWN = 50
function _fails_html(rows)
    fails = [row for row in rows if row.status == "error"]
    isempty(fails) && return ""
    io = IOBuffer()
    print(io, "<details style='margin-top:8px'><summary style='cursor:pointer;font-size:12px;",
              "color:var(--red,#e57575)'>", length(fails), " failed unit",
              length(fails) == 1 ? "" : "s", "</summary>",
              "<div style='max-height:220px;overflow:auto;margin-top:6px'>")
    for f in first(fails, _FAILS_SHOWN)
        print(io, "<div style='margin-bottom:6px;font-size:11px'>",
                  "<code style='color:var(--gold,#ffd700)'>", _esc(string(f.params)), "</code>",
                  "<pre style='margin:2px 0 0;white-space:pre-wrap;opacity:.75'>",
                  _esc(first(String(f.value), 400)), "</pre></div>")
    end
    length(fails) > _FAILS_SHOWN &&
        print(io, "<div style='opacity:.6;font-size:11px'>… and ",
                  length(fails) - _FAILS_SHOWN, " more</div>")
    print(io, "</div></details>")
    return String(take!(io))
end

function Base.show(io::IO, ::MIME"text/html", r::ShardedResult)
    p, t = r.plan, r.telemetry
    frac = BatchSweep.fraction(p)
    armed = BatchSweep.is_armed(store_root(r.target), r.run)
    st = display_state(p, armed)
    col = get(_STATE_COLOR, st, "var(--dim,#6a7090)")

    # `data-sw` hooks mark every part the live script patches; without them it would have to
    # rebuild the card, and the parts that come from Julia (failures, the blocked reason) cannot be
    # rebuilt in the browser.
    print(io, "<div data-sweep='", r.run, "' ",
              # `inherit`, not a font stack: inside the notebook this picks up the page's own UI
              # font, and in a static export it picks up whatever that page uses. Naming a family
              # here would make the card the one element that ignores its surroundings.
              "style='font-family:inherit;color:var(--text,#d4d8e8);",
              "border:1px solid var(--border,#2a2e40);border-radius:8px;padding:12px 14px;",
              "background:var(--bg2,#141828)'>")

    # Header: what state it is in, and how far.
    print(io, "<div style='display:flex;align-items:center;gap:8px;margin-bottom:8px'>",
              "<span data-sw='dot' style='display:inline-block;width:8px;height:8px;",
              "border-radius:50%;background:", col, "'></span>",
              "<strong data-sw='label' style='color:", col, "'>", _state_label(st), "</strong>",
              "<span style='opacity:.5;font-size:12px'>", _esc(r.key), "</span>",
              "<span style='margin-left:auto;font-variant-numeric:tabular-nums'>",
              "<span data-sw='count'>", p.shards_done, " / ", p.shards_total, "</span> ",
              "<span data-sw='pct' style='opacity:.6'>(", round(100 * frac; digits = 1),
              "%)</span></span></div>")

    # Progress bar.
    print(io, "<div style='height:6px;border-radius:3px;background:var(--border,#2a2e40);",
              "overflow:hidden'><div data-sw='bar' style='height:100%;width:",
              round(100 * frac; digits = 2), "%;background:", col, ";transition:width .3s'></div></div>")

    # Counts.
    print(io, "<div style='display:flex;gap:14px;margin-top:8px;font-size:12px'>")
    print(io, "<span data-sw='ok' style='color:var(--green,#56d364)'>", p.shards_ok, " ok</span>")
    print(io, "<span data-sw='failed' style='color:var(--red,#e57575)'>",
              p.shards_failed > 0 ? "$(p.shards_failed) failed" : "", "</span>")
    print(io, "<span data-sw='missing' style='opacity:.6'>",
              p.shards_missing > 0 ? "$(p.shards_missing) remaining" : "", "</span>")
    print(io, "<span data-sw='rate' style='margin-left:auto;opacity:.7'>",
              (t.done > 0 && !BatchSweep.is_settled(p) && !BatchSweep.is_stuck(p) &&
               t.rate_per_s > 0) ? "$(round(t.rate_per_s; digits = 2))/s" : "", "</span>")
    # How much longer, AND when that is. The browser recomputes both on every poll (`data-sw='eta'`),
    # so a card left open overnight is not still promising a finish time from hours ago.
    live_eta = t.done > 0 && !BatchSweep.is_settled(p) && !BatchSweep.is_stuck(p) && t.eta_s >= 0
    print(io, "<span data-sw='eta' style='opacity:.7'>",
              live_eta ? "~$(_dur(t.eta_s)) left · done ~$(_eta_clock(t.eta_s))" : "", "</span>")
    println(io, "</div>")
    print(io, "<div data-sw='note' style='font-size:11px;opacity:.5;margin-top:4px'></div>")
    print(io, "<div style='font-size:11px;color:var(--val,#4ec9b0);opacity:.85;margin-top:4px;",
              "font-family:ui-monospace,monospace'>",
              _esc(_target_line(r.target)), "</div>")

    # The plot of the units that have landed so far — the author's, or the automatic one. Baked in
    # at render time AND patched by the poll, so it is populated before the first round trip and
    # keeps filling after it. The host is emitted only when there is something to draw, so a sweep
    # with no plottable shape does not leave a hole in the card.
    if r.plot !== false
        opt, perr = _plot_option(r.plot, getfield(r, :rows))
        # The host is always emitted but starts HIDDEN, because the automatic plot cannot know its
        # own shape until a unit has landed — and a poll that finally has something to draw needs
        # somewhere to draw it. `drawChart` reveals it on the first option; until then the card
        # shows no empty 280px hole.
        print(io, "<div data-sw='chart' style='height:280px;margin-top:10px",
                  opt === nothing ? ";display:none" : "", "'></div>")
        print(io, "<div data-sw='charterr' style='font-size:11px;color:var(--red,#e57575);margin-top:4px'>",
                  _esc(perr), "</div>")
        opt === nothing ||
            print(io, "<script type='application/json' data-sw='chartopt'>", _json(opt), "</script>")
    end

    _unit_grid(io, r)

    hosts = r.hosts
    isempty(hosts) || print(io, "<div style='font-size:11px;opacity:.5;margin-top:8px'>ran on ",
                                _esc(join(first(hosts, 8), ", ")),
                                length(hosts) > 8 ? " (+$(length(hosts) - 8))" : "", "</div>")

    idle = BatchSweep.stalled_for(t)
    idle > 0 && print(io, "<div style='margin-top:8px;font-size:12px;color:var(--gold,#ffd700)'>",
                          "⚠ nothing has finished in ", _dur(idle), " — it may be stuck.</div>")

    # Both of these are emitted as CONTAINERS even when empty, and their contents ride the poll —
    # a sweep that starts failing while you watch it has to grow its own explanation and error list.
    # Rendered here rather than rebuilt in the browser so there is one renderer and it cannot drift.
    print(io, "<div data-sw='data'>", _data_html(r.dataset), "</div>")
    println(io, "<div data-sw='why'>", _why_html(p), "</div>")
    println(io, "<div data-sw='fails'>", _fails_html(getfield(r, :rows)), "</div>")

    _actions(io, r)
    _live_script(io, r)
    println(io, "</div>")
    return nothing
end

# Only the controls that apply to the state it is in. A "Cancel" on a finished sweep or a "Resume"
# on one that was never stopped is a button that either does nothing or does something surprising.
#
# Computed here and ALSO sent on every poll, so the browser can rebuild the row as the state moves.
# It used to be rendered once by the cell and then left alone, which made the controls lie: cancel a
# running sweep and the button still read "Cancel" while the card beside it said "stopped at your
# request" — indistinguishable from a cancel that did nothing, and with no way to resume short of
# re-running the cell.
# What the card SAYS a sweep is. `Plan.state` describes the store and the scheduler; this adds the
# one thing only the notebook knows — whether anyone has asked for the work. A sweep with units
# outstanding that has not been armed is READY, not pending: nothing is queued and nothing will be
# until it is submitted.
display_state(p::BatchSweep.Plan, armed::Bool) =
    (!armed && p.state === :pending) ? :ready : p.state

function action_list(p::BatchSweep.Plan, armed::Bool = true)
    st = display_state(p, armed)
    acts = Tuple{String,String}[]
    if st === :ready
        # The one control that spends anything, and it says how much before you press it.
        n = p.shards_missing
        push!(acts, ("submit", "Submit $(n) unit" * (n == 1 ? "" : "s")))
    elseif st === :running || st === :pending
        push!(acts, ("cancel", "Cancel"))
    elseif st === :cancelled
        push!(acts, ("resume", "Resume"))
    end
    p.shards_failed > 0 && push!(acts, ("retry", "Retry $(p.shards_failed) failed"))
    # Reset is available the moment there is anything to throw away — finished units, submission
    # history, or work in flight. Offering it only once a sweep had settled stranded the case you
    # most want out of: a long run that is half done and going wrong. It is confirmed in the browser
    # rather than rationed here.
    (p.shards_done > 0 || armed || p.state in (:cancelled, :blocked, :exhausted)) &&
        push!(acts, ("reset", "Reset"))
    return acts
end

const _BTN_STYLE = "font:inherit;font-size:11px;padding:3px 9px;border-radius:5px;cursor:pointer;" *
                   "border:1px solid var(--border,#2a2e40);background:transparent;" *
                   "color:var(--text,#d4d8e8)"

function _actions(io, r::ShardedResult)
    # The container is emitted even when empty: the live script repopulates it, and a card that
    # rendered with nothing to offer must still be able to grow a Retry when a unit fails.
    print(io, "<div data-sw='acts' style='display:flex;gap:6px;margin-top:10px'>")
    for (act, label) in action_list(r.plan, BatchSweep.is_armed(store_root(r.target), r.run))
        print(io, "<button data-sw-do='", act, "' style='", _BTN_STYLE, "'>", _esc(label), "</button>")
    end
    println(io, "</div>")
end

# Poll the sweep's channel and patch the card in place. Only while there is something to wait for:
# a settled sweep renders static and starts no timer, so a notebook full of finished sweeps costs
# nothing. The interval backs off as a run gets long, because a sweep of hours does not need
# second-by-second updates and the poll is a round trip to the scheduler.
function _live_script(io, r::ShardedResult)
    ch = status_channel(r.run)
    doch = action_channel(r.run)
    # The buttons are wired whatever the state; only the POLL is conditional. A finished sweep still
    # offers Retry and Reset, and a card that started no timer must not be inert.
    # Nothing to watch on a sweep that is finished, stopped, or not yet submitted.
    poll = !(BatchSweep.is_settled(r.plan) || BatchSweep.is_stuck(r.plan) ||
             display_state(r.plan, BatchSweep.is_armed(store_root(r.target), r.run)) === :ready)
    id = r.run
    print(io, """
    <script>
    (function(){
      var root = document.currentScript.closest('[data-sweep="$(id)"]') ||
                 document.currentScript.parentElement;
      if (!root || root.dataset.swLive === "1") return;
      root.dataset.swLive = "1";
      var started = Date.now(), timer = null, chart = null, settled = false;
      var watching = $(poll ? "true" : "false");   // was there anything left to watch at render?
      // The last state the card knows about, seeded from the render so the buttons can speak
      // accurately before the first poll lands.
      var last = { done: $(r.plan.shards_done), total: $(r.plan.shards_total),
                   state: "$(display_state(r.plan, BatchSweep.is_armed(store_root(r.target), r.run)))" };

      // "~3h12m left" is a number you then have to add to the clock. "done ~17:22" is one you can
      // act on. Both, because the first says whether to wait and the second says what to do instead.
      function dur(s){
        if (s < 0) return "?";
        if (s < 60) return "~" + Math.round(s) + "s";
        if (s < 3600) return "~" + Math.round(s / 60) + "m";
        if (s < 86400) return "~" + Math.floor(s / 3600) + "h" +
                       String(Math.round((s % 3600) / 60)).padStart(2, "0") + "m";
        return "~" + (s / 86400).toFixed(1) + "d";
      }
      function clock(s){
        var t = new Date(Date.now() + s * 1000), now = new Date();
        var hhmm = String(t.getHours()).padStart(2, "0") + ":" + String(t.getMinutes()).padStart(2, "0");
        // The date comes along once the answer is not today: "done ~09:20" on a run that lands
        // tomorrow morning is worse than no answer at all.
        if (t.toDateString() === now.toDateString()) return hhmm;
        var days = Math.round((t - now) / 86400000);
        return (days <= 6 ? t.toLocaleDateString(undefined, { weekday: "short" })
                          : t.toLocaleDateString(undefined, { day: "numeric", month: "short" })) + " " + hhmm;
      }
      function interval(){
        // A sweep that has SETTLED still has a figure that moves: how much of its output has been
        // read. Reads happen after the work finishes — that is when you read it — so a card that
        // stopped polling on settle froze its data line at "nothing read" and the topbar total with
        // it. Slow heartbeat rather than a stop, and only for a sweep that HAS a dataset.
        // Deliberately slack: a poll costs one manifest read per unit, so a finished sweep of a few
        // thousand units is not something to ask about every two seconds for the rest of a session.
        if (settled) return 30000;
        var mins = (Date.now() - started) / 60000;
        return mins < 2 ? 2000 : mins < 15 ? 5000 : 15000;
      }
      // The chart is created lazily and reused: `setOption` on a live instance animates from the
      // points already drawn, which is what makes a sweep look like it is FILLING rather than
      // redrawing. Slate's own runtime supplies the themed instance, so it matches every other
      // chart in the notebook and follows a theme switch.
      function drawChart(opt){
        var el = root.querySelector('[data-sw="chart"]');
        if (!el || !opt || !window.echarts) return;
        if (!chart) {
          chart = window.chartRuntime ? window.chartRuntime.init(el) : window.echarts.init(el);
        }
        try { chart.setOption(opt, { notMerge: false, lazyUpdate: true }); } catch (e) {}
      }
      function paint(s){
        last = s;
        // Feed the notebook-level pill. The card is inside one cell's output; the pill is what
        // answers "what is this notebook doing" when that cell is scrolled away or collapsed.
        if (window.slateSweeps) {
          var cell = root.closest('[data-cid]');
          window.slateSweeps.report("$(id)", cell ? cell.dataset.cid : "", s);
        }
        if (s.chart) drawChart(s.chart);
        var ce = root.querySelector('[data-sw="charterr"]');
        if (ce) ce.textContent = s.charterr || "";
        syncActions(s.actions);
        // Why it stopped, and which units failed. Rendered by Julia and swapped in whole, so the
        // browser holds no second copy of this markup to drift from the cell's own render. Only on
        // CHANGE, so an open <details> is not collapsed underneath the reader on every poll.
        ["why", "fails", "data"].forEach(function(k){
          var el = root.querySelector('[data-sw="' + k + '"]');
          if (!el || s[k] === undefined) return;
          if (el.dataset.h !== s[k]) { el.dataset.h = s[k]; el.innerHTML = s[k]; }
        });
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
        // How much longer, and WHEN that is. Computed in the browser so the clock time is the
        // reader's own — a hub in another timezone would otherwise quote a finish time in its.
        set("eta", (s.eta >= 0 && !s.settled && !s.stuck) ? dur(s.eta) + " left · done ~" + clock(s.eta) : "");
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
        // Submitting turns a card that had nothing to watch into a live one, so the timer starts
        // here rather than only at render.
        if (!s.settled && !s.blocked && s.state !== "ready" && !timer) {
          watching = true;
          timer = setInterval(tick, interval());
        }
        if (s.settled || s.blocked){
          clearInterval(timer); timer = null;
          // …but a sweep holding a DATASET is not finished changing: how much of it has been read
          // moves every time a cell slices it, which is after the work is over. Keep a slow
          // heartbeat for that one figure so the card and the topbar total stay true.
          if (s.dsbytes > 0) { settled = true; timer = setInterval(tick, interval()); }
          // Tell Julia ONCE that the work is over, so the cells that read this sweep recompute.
          // Only for a settle we actually WATCHED: a card that rendered already-finished has
          // nothing to announce, and announcing anyway would restale the notebook's downstream
          // cells on every page load.
          if (watching && !root.dataset.swSettledSent) {
            root.dataset.swSettledSent = "1";
            if (window.slateCall) window.slateCall("$(doch)", { action: "settled" }).catch(function(){});
          }
          // The card's remaining detail (failures, the blocked reason) comes from Julia, so hand
          // back to the cell rather than trying to rebuild it here.
          var n = root.querySelector('[data-sw="note"]');
          if (n) n.textContent = s.blocked ? s.blocked : "finished";
        }
      }
      function tick(){
        if (!document.body.contains(root)) { clearInterval(timer); return; }
        if (!window.slateCall) return;
        window.slateCall("$(ch)", {}).then(paint).catch(function(){ clearInterval(timer); });
      }

      // Buttons. Disabled while the call is in flight so an impatient second click cannot cancel
      // and resume in the same breath. The click's reply carries the new state, so the row rebuilds
      // itself — cancel a sweep and the button becomes Resume, in that same round trip.
      // Reset is the one control that DESTROYS work — hours of cluster time, in the case it exists
      // for. It is confirmed, and the confirmation says what goes rather than asking "are you sure":
      // the count of finished units is the number someone needs to weigh.
      function confirmReset(){
        var n = last.done || 0, live = last.state === "running" || last.state === "pending";
        var msg = n > 0 ? "Discard " + n + " finished unit" + (n === 1 ? "" : "s") + " and start over?"
                        : "Reset this sweep?";
        if (live) msg += "\\nAnything still queued or running is cancelled.";
        return window.confirmDark ? window.confirmDark(msg, "Reset", "danger")
                                  : Promise.resolve(window.confirm(msg));
      }
      function runAction(act, btn){
        if (btn.disabled) return;
        var was = btn.textContent;
        // Disabled for the confirmation too, not just the call: an impatient second click would
        // otherwise stack a second dialog on the first.
        btn.disabled = true;
        (act === "reset" ? confirmReset() : Promise.resolve(true)).then(function(ok){
          if (!ok) { btn.disabled = false; return; }
          btn.textContent = "…";
          window.slateCall("$(doch)", { action: act }).then(paint).catch(function(e){
            btn.disabled = false; btn.textContent = was;
            var n = root.querySelector('[data-sw="note"]');
            if (n) n.textContent = String(e);
          });
        });
      }
      // Rebuild the control row only when the SET of actions changed, so a click never lands on a
      // button that a poll replaced underneath it mid-press.
      function syncActions(list){
        var host = root.querySelector('[data-sw="acts"]');
        if (!host || !list) return;
        var want = list.map(function(a){ return a[0] + "|" + a[1]; }).join(",");
        if (host.dataset.sig === want) return;
        host.dataset.sig = want;
        host.textContent = "";
        list.forEach(function(a){
          var b = document.createElement("button");
          b.dataset.swDo = a[0];
          b.textContent = a[1];
          b.setAttribute("style", "$(_BTN_STYLE)");
          b.addEventListener("click", function(){ runAction(a[0], b); });
          host.appendChild(b);
        });
      }

      // Wire the buttons the CELL rendered, and record what they are — so they work before the
      // first poll lands, and an unchanged state does not churn the row underneath a click.
      (function(){
        var host = root.querySelector('[data-sw="acts"]');
        if (!host) return;
        var sig = [];
        host.querySelectorAll('[data-sw-do]').forEach(function(b){
          sig.push(b.dataset.swDo + "|" + b.textContent);
          b.addEventListener('click', function(){ runAction(b.dataset.swDo, b); });
        });
        host.dataset.sig = sig.join(",");
      })();

      // Draw the option baked in at render time before any round trip, so a settled sweep's chart
      // is there on load and an exported page shows it with no server at all.
      var seed = root.querySelector('script[data-sw="chartopt"]');
      if (seed) { try { drawChart(JSON.parse(seed.textContent)); } catch (e) {} }

      // One tick ALWAYS, so a finished sweep still reports itself to the topbar pill; the repeating
      // timer only starts when there is something left to watch.
      tick();
      if (watching) timer = setInterval(tick, interval());
    })();
    </script>""")
end

function Base.show(io::IO, ::MIME"text/plain", r::ShardedResult)
    p = r.plan
    t = r.telemetry
    st = display_state(p, BatchSweep.is_armed(store_root(r.target), r.run))
    icon = st === :succeeded ? "✅" : st === :partial   ? "⚠️" :
           st === :exhausted ? "⛔" : st === :blocked   ? "🛑" :
           st === :cancelled ? "⏹" : st === :running   ? "⏳" :
           st === :ready     ? "○"  : "•"
    pct = round(100 * BatchSweep.fraction(p); digits = 1)
    println(io, "$icon sweep $(r.key) — $(st)")
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

    hosts = r.hosts
    isempty(hosts) || println(io, "   ran on: ", join(first(hosts, 6), ", "),
                              length(hosts) > 6 ? " (+$(length(hosts) - 6) more)" : "")

    idle = BatchSweep.stalled_for(t)
    idle > 0 && println(io, "   ⚠ nothing has finished in $(_dur(idle)) — it may be stuck.")

    if p.state === :blocked
        println(io, "   🛑 $(p.blocked)")
        println(io, "   Nothing further will be submitted. Fix the body, then `Sweep.reset!(r)`.")
    elseif p.state === :cancelled
        println(io, "   Stopped at your request. $(p.shards_done) finished units are kept — ",
                    "`Sweep.resume!(r)` continues with the remaining $(p.shards_missing).")
    elseif p.state === :partial
        println(io, "   `r.errors` lists them; `Sweep.retry_failed!(r)` clears them for a retry.")
    elseif p.state === :exhausted
        println(io, "   Attempted $(BatchSweep.MAX_ATTEMPTS)× without landing, so these units are ",
                    "outrunning their resources rather than erroring.")
        println(io, "   Raise the walltime or memory, then `Sweep.reset!(r)`.")
    elseif p.state !== :succeeded
        println(io, "   re-run this cell to refresh.")
    end
end

# ── The sweep itself ─────────────────────────────────────────────────────────────────────────

"""
    run_sweep(target, params, body_src; setup_src = "", captures = Dict(), submit = true) -> ShardedResult

The function `@sweep` expands to. Idempotent: it works out what is missing, submits exactly that,
and returns immediately with whatever has already landed.

It never waits for completion, and there is deliberately no option to. A cell that blocks for the
length of the work puts the notebook back where it started — one opaque "running" chip, no partial
results, nothing else runnable — and on a cluster the work can outlive the browser, the worker and
the machine. "Running" here means submitted, scheduled and being watched; the card and the topbar
pill carry the rest.
"""
function run_sweep(target::SweepTarget, params::AbstractVector, body_src::AbstractString;
                   setup_src::AbstractString = "", captures::AbstractDict = Dict{Symbol,Any}(),
                   submit::Bool = false, cap::Integer = 0, register = nothing,
                   resources = nothing, plot = nothing, refresh = nothing, cell = "",
                   summary_src::AbstractString = "", lazy::Bool = false,
                   attrs::AbstractDict = Dict{String,String}())
    # Resource overrides do NOT enter the key. Re-running the same body with a longer walltime is
    # the same sweep resumed, not a different one — otherwise the fix for a walltime kill would
    # throw away every unit that had already survived it.
    #
    # The cell HEADER wins over a `resources =` written in the source. Both are explicit, but the
    # header is the one a person edits from the UI while watching a job, and a control that silently
    # loses to the source would be a control that appears broken.
    target = with_resources(with_resources(target, resources), attr_resources(attrs))
    target = with_chunk(target, attr_chunk(attrs))
    # Storage FORM, not identity: a unit's value is the same either way, so flipping `data=` must
    # not re-key and throw away finished work. Units already stored whole simply have no index and
    # cannot be sliced; the dataset says how many, rather than quietly omitting them.
    lazy = lazy || attr_lazy(attrs)
    # What has landed since last time. For a remote cluster this is the one round trip that makes
    # every manifest read below local; for a local target it is a no-op.
    sync_in!(target)
    root = store_root(target)
    mkpath(root)
    key = sweep_key(body_src, setup_src, captures, env_key(target), summary_src)
    keys = [shard_key(key, prm) for prm in params]
    run = run_key(key, keys)

    # (Re)write the descriptors. Content-addressed, so doing this every run is nearly free: the
    # blobs already exist and only ~1 KB of manifests is rewritten.
    per = max(1, chunk_size(target))
    chunks = String[]
    for (ci, lo) in enumerate(1:per:length(params))
        hi = min(lo + per - 1, length(params))
        ck = chunk_key(run, ci)
        SlateTask.write_chunk!(root, ck; fn_src = body_src, setup_src = setup_src,
                               captures = Dict(String(k) => v for (k, v) in captures),
                               params = params[lo:hi], keys = keys[lo:hi],
                               summary_src = summary_src, lazy = lazy)
        push!(chunks, ck)
    end
    BatchSweep.write_sweep!(root, run, chunks)
    # The job cannot start without its descriptors, so they go over BEFORE anything is submitted.
    sync_out!(target)

    launcher = launcher_for(target)
    # Running the cell RECONCILES; it does not submit. Authoring a sweep means running the cell
    # repeatedly, and every one of those must be free — the work starts when someone asks for it,
    # from the card. `submit = true` is for a standalone script, where there is no card to ask from.
    submit && BatchSweep.arm!(root, run)
    reconcile_and_sync!(target, run, launcher; cap, submit = BatchSweep.is_armed(root, run))
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
        # What "the sweep finished" tells the notebook. `slate_refresh` restales the cells that READ
        # a name without re-running the one that WRITES it, which is precisely right here: the sweep
        # cell must not resubmit, and everything downstream of it should recompute. The cell does not
        # know what the notebook named its result, so it names ITSELF and the hub resolves that to
        # the names the cell writes.
        note = (refresh === nothing || isempty(cell)) ? nothing : () -> refresh("cell:" * cell)
        register(status_channel(run), _args -> status_payload(target, run, ps, ks; plot))
        register(action_channel(run),
                 a -> handle_action(target, run, ps, ks, String(get(a, :action, ""));
                                    plot, notify = note))
    end

    pl = BatchSweep.plan(root, run; launcher)
    tl = BatchSweep.telemetry(root, run; launcher, plan = pl)
    return ShardedResult(key, run, target, collect(params), keys, pl,
                         _rows(root, params, keys, source_of(target)), tl, plot)
end

# Free names in the body that are bound in the calling module and look like DATA. These travel with
# the sweep as serialized captures.
#
# Functions, modules, and types are deliberately excluded: a compute node cannot revive a function
# value, only source. Helpers therefore belong in `setup=`, which travels as text.
# Lift `using` / `import` out of a body, returning them and what is left. They are legal to WRITE
# there — the parser accepts them anywhere — but not to run: a closure cannot carry an import, and a
# module wants loading once per process rather than once per unit.
function _hoist_imports(ex)
    ex isa Expr || return (Expr[], ex)
    found = Expr[]
    strip_(e) = e
    function strip_(e::Expr)
        if e.head in (:block, :toplevel)
            kept = Any[]
            for a in e.args
                if a isa Expr && a.head in (:using, :import)
                    push!(found, a)
                else
                    push!(kept, strip_(a))
                end
            end
            return Expr(e.head, kept...)
        end
        return e
    end
    body = strip_(ex)
    # A lone `using` as the whole body leaves nothing behind; keep it valid.
    (body isa Expr && body.head === :block && isempty(body.args)) && (body = Expr(:block, nothing))
    return (found, body)
end

# Augmented assignment. `x += 1` needs `x` to exist, but inside a function body it makes `x` local
# all the same, so the target is a binding here like any other.
const _AUG_ASSIGN = Set{Symbol}([:+=, :-=, :*=, :/=, ://=, :\=, :^=, :%=, :÷=, :|=, :&=, :⊻=,
                                 :>>>=, :>>=, :<<=])

"""
    _capture_names(body, param) -> Set{Symbol}

The names the body reads from the notebook — the values that have to travel with it.

Scope matters here, and a plain symbol scrape does not have it. A comprehension variable, a loop
variable or a local assignment is bound INSIDE the body; counting one as free captures whatever the
notebook happens to keep under that name. Captures enter the sweep key, so an unrelated cell
assigning to that name re-keys the sweep and orphans every result it has already computed.

Bound names are collected flat over the whole body, which is also how Julia scopes a plain
assignment inside a function. Where the two differ — a name used as a loop variable in one place
and read as a global in another — this errs toward NOT capturing, so the unit fails on the compute
node with an `UndefVarError` naming the variable rather than running against an unrelated value.
"""
function _capture_names(body, param::Symbol)
    bound = _bound_names(body)
    push!(bound, param)
    free = Set{Symbol}()
    read_(x) = nothing
    read_(s::Symbol) = (s in bound || push!(free, s); nothing)
    function read_(e::Expr)
        h = e.head
        h === :quote && return nothing                          # quoted code holds no variable reads
        if h === :. && length(e.args) == 2                      # `a.b` — `b` names a field
            read_(e.args[1]); return nothing
        elseif h === :kw && length(e.args) == 2                 # `f(; k = v)` — `k` names a keyword
            read_(e.args[2]); return nothing
        end
        for a in e.args; read_(a); end
        return nothing
    end
    read_(body)
    return free
end

# Every name the body BINDS: assignment targets, loop and comprehension variables, `let` bindings,
# the parameters and names of functions defined inside it, `local` declarations. Only binding
# POSITIONS are collected — a right-hand side is a read, and belongs to `_capture_names`.
function _bound_names(body)
    out = Set{Symbol}()
    # A binding target: `x`, `(a, b)`, `x::T`, `x = default`, `x...`, or a `f(a, b)` signature.
    # Heads that are absent on purpose: `a[i] = v` and `a.f = v` assign THROUGH a variable rather
    # than binding one, so they fall through and `a` stays a read.
    tgt(x) = nothing
    tgt(s::Symbol) = (push!(out, s); nothing)
    function tgt(e::Expr)
        if e.head in (:tuple, :parameters, :call)
            for a in e.args; tgt(a); end
        elseif e.head in (:(::), :(=), :kw, :..., :where) && !isempty(e.args)
            tgt(e.args[1])
        end
        return nothing
    end
    # `for x in it`, `[… for x in it]` and their multi-variable forms all carry their variables in
    # `x = it` / `x in it` specs, optionally wrapped in a `:block` (`for i in a, j in b`) or a
    # `:filter` (`… for x in it if p(x)`).
    spec(x) = nothing
    function spec(e::Expr)
        if e.head === :block || e.head === :filter
            for a in e.args; spec(a); end
        elseif e.head in (:(=), :in) && !isempty(e.args)
            tgt(e.args[1])
        end
        return nothing
    end
    walk(x) = nothing
    function walk(e::Expr)
        h = e.head
        if h === :(=) || h in _AUG_ASSIGN
            !isempty(e.args) && tgt(e.args[1])
        elseif h === :for
            !isempty(e.args) && spec(e.args[1])
        elseif h === :generator
            for a in Iterators.drop(e.args, 1); spec(a); end
        elseif h === :let
            !isempty(e.args) && spec(e.args[1])
            # `let x; … end` declares without assigning, which `spec` does not see as a binding.
            b = e.args[1]
            b isa Symbol && tgt(b)
            b isa Expr && b.head === :block && for a in b.args; a isa Symbol && tgt(a); end
        elseif h === :function || h === :->
            # A `f(x) do y … end` is `:do(call, ->)`: the lambda's parameters are on the `->`, which
            # this branch catches on the way down. Binding the CALL's arguments instead would be
            # wrong — they are reads.
            !isempty(e.args) && tgt(e.args[1])
        elseif h === :local
            for a in e.args; tgt(a); end
        end
        for a in e.args; walk(a); end
        return nothing
    end
    walk(body)
    return out
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

  * plain data from the notebook, which is captured and serialized automatically;
  * `using` / `import`, written in the body and lifted out to run once per chunk; and
  * helper definitions, which go in `setup = begin … end` — a function value cannot be revived on a
    compute node, so helpers travel as code too.

    @sweep(paramgrid(β = 0:0.1:2), hpc) do p
        using MyPkg
        MyPkg.simulate(p)
    end

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
    # The target is OPTIONAL. `@sweep(grid) do … end` in a `#%% sweep cluster=hpc` cell takes its
    # target from the notebook's cluster definitions, so where the work runs is configuration rather
    # than something each cell restates.
    isempty(positional) &&
        error("@sweep needs a grid: `@sweep(grid) do p … end`, with `cluster=<name>` on the cell " *
              "header — or `@sweep(grid, target) do p … end`")
    grid = positional[1]
    target = length(positional) >= 2 ? positional[2] : nothing

    # The do-block's parameter and body, as written.
    plist = body.args[1]
    param = plist isa Symbol ? plist :
            (plist isa Expr && plist.head === :tuple && length(plist.args) == 1) ? plist.args[1] :
            error("@sweep's do-block takes exactly one parameter")
    inner = body.args[2]

    # Line information is stripped before the body is stringified. It is part of the key, so
    # leaving it in would mean a sweep re-keys — orphaning every result it already has — because a
    # cell moved down the notebook or gained a comment above it.
    # `using MyPkg` written in the body, where you would expect to write it. It is lifted out into
    # the chunk's setup: a module has to be loaded once per PROCESS, not once per unit, and a
    # closure cannot carry an import anyway.
    imports, inner = _hoist_imports(_strip_lines(inner))

    body_src = string(param, " -> begin\n", string(inner), "\nend")
    names = _capture_names(inner, param)
    cap    = get(opts, :cap, 0)
    submit = get(opts, :submit, false)
    res    = get(opts, :resources, nothing)
    plot   = get(opts, :plot, nothing)
    lazy   = get(opts, :lazy, false)
    # An unknown option is an error rather than a silent no-op: `@sweep(…, wallclock = "2h")` that
    # quietly does nothing is worse than one that says so.
    for k in keys(opts)
        k in (:setup, :cap, :submit, :resources, :plot, :summary, :lazy) ||
            error("@sweep: unknown option `$k` " *
                  "(accepted: setup, cap, submit, resources, plot, summary, lazy)")
    end

    # What the shard module needs before the body runs: the imports lifted out of the body, then
    # anything `setup` adds. `setup` takes Julia — a `begin … end` of helper definitions — rather
    # than a string, so it is parsed, highlighted and indented like the code it is.
    setup_lines = [string(im) for im in imports]
    if haskey(opts, :setup)
        e = opts[:setup]
        push!(setup_lines,
              e isa AbstractString ? String(e) :                          # already source
              (e isa Expr && e.head in (:block, :quote)) ?
                  string(_strip_lines(e.head === :quote ? e.args[1] : e)) :
                  string(_strip_lines(e)))
    end
    setup = join(setup_lines, "\n")
    # `summary` runs on the COMPUTE NODE, so like the body it travels as source. Given a one-argument
    # function it is stringified whole; given an expression it is wrapped as `v -> …`, so
    # `summary = sum(abs2, v)` reads the way it should.
    sumsrc = ""
    if haskey(opts, :summary)
        e = _strip_lines(opts[:summary])
        sumsrc = (e isa Expr && e.head === :(->)) ? string(e) : string("v -> ", string(e))
    end

    quote
        local _names = $(QuoteNode(collect(names)))
        local _caps = $(Sweep)._collect_captures(@__MODULE__, _names, $(QuoteNode(param)))
        # `slate_on` is injected into a notebook's namespace, so it is reachable from here and
        # nowhere else. Picking it up automatically is what lets a sweep cell be live without the
        # author registering anything.
        local _reg = isdefined(@__MODULE__, :slate_on) ?
                     getfield(@__MODULE__, :slate_on) : nothing
        # `slate_refresh` + the id of the cell being evaluated: together they let a sweep that
        # finishes long after this cell returned tell the notebook to recompute what reads it.
        local _refresh = isdefined(@__MODULE__, :slate_refresh) ?
                         getfield(@__MODULE__, :slate_refresh) : nothing
        local _cell = get(task_local_storage(), :slate_cell, "")
        # The cell's own `key=value` header attributes — where a `#%% sweep` cell keeps its
        # walltime, partition and memory, so they can be changed from the UI without editing code.
        local _sctx = get(task_local_storage(), :slate_ctx, nothing)
        local _attrs = (_sctx !== nothing && hasproperty(_sctx, :attrs)) ?
                       _sctx.attrs : Dict{String,String}()
        local _clusters = (_sctx !== nothing && hasproperty(_sctx, :clusters)) ?
                          _sctx.clusters : Dict{String,Dict{String,String}}()
        $(Sweep).run_sweep($(Sweep).resolve_target($(esc(target)), _attrs, _clusters),
                           collect($(esc(grid))), $body_src;
                           setup_src = $setup, captures = _caps,
                           cap = $(esc(cap)), submit = $(esc(submit)), register = _reg,
                           resources = $(esc(res)), plot = $(esc(plot)),
                           summary_src = $sumsrc, lazy = $(esc(lazy)),
                           refresh = _refresh, cell = String(_cell), attrs = _attrs)
    end
end

end # module Sweep
