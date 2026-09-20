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

# Path homes, the ssh session everything below rides, and the prompts it raises when a cluster will
# not take a key. IMPORTED from the parent when there is one: each holds process-wide state — the
# pending prompts, the open sessions — and a second copy would be a second set of them, so an answer
# would never reach the prompt waiting for it. Included only when this file is loaded standalone, as
# the worker loads it.
for (name, file) in ((:SlateHome, "slate_home.jl"), (:SshAuth, "sshauth.jl"),
                     (:SshTransport, "sshtransport.jl"))
    if isdefined(parentmodule(@__MODULE__), name)
        Core.eval(@__MODULE__, :(import ..$name))
    else
        Base.include(@__MODULE__, joinpath(@__DIR__, file))
    end
end

# Reaching a store the hub has no filesystem access to — the mirror and the transport that keeps it
# in step. Separate because it is transport with no opinion about sweeps.
Base.include(@__MODULE__, joinpath(@__DIR__, "remotestore.jl"))

# The env-preparation policy shared by the notebook fork and the remote provisioner. envprep.jl is
# pure TOML/file operations with no transport of its own, precisely so a new transport can reuse it:
# batch is the third, after the local filesystem fork and a remote store over ssh.
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
export paramgrid, @sweep, SweepTarget, LocalTarget, ClusterTarget, SlurmTarget, PbsTarget

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

# Provisioning runs on the host's one authenticated session, like everything else here.
_ssh_run(host, script; capture::Bool = false) = run_there(String(host), String(script))

"""
    provision_payload!(host, root_remote) -> path

Put the task runner where a compute node can load it, and return the path it will use.

The runner is Slate's own code, not the user's — a handful of stdlib-only files that every job
`include`s. It goes over the host's one authenticated session, because that is the only way in: a
cluster's filesystem is reachable from its nodes, not from here. A few KB, so it is sent each time
rather than compared first.
"""
function provision_payload!(host::AbstractString, root_remote::AbstractString)
    # Say the one thing that is wrong. Wrapped in "could not create <path> on <host>", a missing
    # sign-in reads as a permissions or filesystem problem on the cluster.
    connected(host) || error(_offline(host))
    dst = "$(root_remote)/src"
    ok, out = _ssh_run(host, "mkdir -p $(dst)")
    ok || error("could not create $(dst) on $(host): $(strip(out))")
    src = dirname(String(first(methods(paramgrid)).file))
    files = [joinpath(src, f) for f in SlateTask.PAYLOAD_FILES]
    put_files(host, files, dst) ||
        error("could not ship the task runner to $(host):$(dst)")
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
    connected(host) || error(_offline(host))
    isempty(parent) && return joinpath(root_remote, "env")
    # Source-inclusive, for the same reason as `task_env!`: the cluster's copy is made once, so an
    # edit the fingerprint cannot see is an edit the compute nodes never get.
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

    # The project itself. Replaced rather than merged, so a source file deleted here does not linger
    # over there and get loaded. Manifest.toml is excluded: the cluster resolves its own.
    put_dir(host, rstrip(parent, '/'), remote_pkg;
            delete = true, excludes = [".git", "Manifest.toml"]) ||
        error("could not copy $(parent) to $(host):$(remote_pkg)")

    pre = isempty(prologue) ? "" : prologue * "\n"
    dev = isempty(pname) ? "" : "Pkg.develop(Pkg.PackageSpec(path=raw\"$(remote_pkg)\"));"
    # The parent's deps become DIRECT deps of the task environment, not merely transitive ones.
    #
    # `develop` alone makes them reachable from the parent package's own code and nowhere else: a
    # sweep body runs at top level IN this environment, and Julia resolves `using Foo` against the
    # active project's direct deps. So a parent that lists a package precisely so the compute nodes
    # have it — which is the whole reason a task-env package carries deps it never imports — got an
    # environment where `using` it still failed. Loading by UUID happened to work, which is why the
    # one package Slate loads that way (Arrow) masked this for as long as it did.
    depnames = try
        pt = Pkg.TOML.parsefile(joinpath(parent, "Project.toml"))
        sort!(String[k for k in keys(get(pt, "deps", Dict{String,Any}()))])
    catch
        String[]
    end
    addl = isempty(depnames) ? "" :
        "Pkg.add([" * join(("Pkg.PackageSpec(name=raw\"$(d)\")" for d in depnames), ", ") * "]);"
    code = "using Pkg; Pkg.activate(raw\"$(envdir)\"); $dev $addl Pkg.instantiate(); Pkg.precompile()"
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
    procs::Int                   # concurrent task processes; 0 = follow `local_procs()`
    probe::Int                   # chunks released before any unit has finished (`@sweep(probe=)`)
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
                     payload = joinpath(@__DIR__, "slatetask.jl"), chunk = 8, procs = 0,
                     probe = 1)
    mkpath(String(root))
    proj = project === nothing ? task_env!(String(root), String(parent), env) : String(project)
    LocalTarget(String(root), proj, String(payload), Int(chunk), Int(procs), Int(probe))
end

# ── How much of this machine a local sweep may take ──────────────────────────────────────────
# Each task is a WHOLE Julia loading the project, so the binding constraint is memory, not cores —
# which is why the default is far below the core count and capped. A workstation with room to spare
# can say so; a laptop should not have to discover the limit by swapping.
#
# Set from `slate.json` at boot (see `KaimonSlate.local_procs`); 0 means "work it out from this
# machine". A cluster definition's own `procs` outranks it, the same layering `read_limit` uses.
const LOCAL_PROCS = Ref(0)

"""
    local_procs() -> Int
    local_procs(t::LocalTarget) -> Int

How many task processes may run at once: the target's own `procs` if it names one, else the session
setting, else what this machine can be expected to hold. The no-argument form is what a target that
says nothing will get, which is what the cluster editor shows as its placeholder.
"""
local_procs() = LOCAL_PROCS[] > 0 ? LOCAL_PROCS[] : BatchLauncher.default_maxproc()
local_procs(t::LocalTarget) = t.procs > 0 ? t.procs : local_procs()

"""
    ClusterTarget(host; kind, root, root_remote, project, payload, resources, chunk)

Submit shards to a batch scheduler through `host` (a login node in `~/.ssh/config`; `""` runs the
client tools locally, which is the case when Slate itself runs on a login node). `SlurmTarget` and
`PbsTarget` are this with `kind` already chosen.

`root` is the store as the HUB sees it and `root_remote` as a COMPUTE NODE sees it. They are the
same store; on a real cluster they are the same path, and they differ only when something is
mounted differently on the two sides.

Which scheduler is a property of the CLUSTER, not of a second kind of target: everything below —
the store, provisioning, the environment key, how a sweep is planned — is identical either way, and
only `launcher_for` differs. A second struct would have duplicated twenty methods to change one.
"""
struct ClusterTarget <: SweepTarget
    kind::Symbol        # :slurm | :pbs | :exec — what schedules the work on `host`
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
    # Scheduler options with no field of their own, verbatim, one per line. A site's own flags
    # (`--licenses`, `--switches`) and anything whose value a cell header cannot carry.
    directives::String
    parent::String      # what the task environment is built from; `project` overrides it
    julia::String       # the julia to build that environment with, as the login node names it
    procs::Int          # `exec` only: processes at once on `host`; 0 = follow `local_procs()`
    # How private this store is, as an octal directory mode: "0700" (default) or "0750" for a site
    # where a project group is meant to read each other's runs. A store lives on scratch — outside
    # whatever a home directory protects — and holds results, job output, and the SOURCE of the body
    # that produced them. Empty follows the site's own umask, which is routinely world-readable.
    mode::String
    probe::Int          # chunks released before any unit has finished (`@sweep(probe=)`)
end
#
# A target DESCRIBES a cluster; it does not reach one. `parent` and an empty `project`/`payload` mean
# "build the environment and ship the runner when there is a job to submit" — see `provision!`. Pass
# `project` to point at an environment the site already manages, in which case nothing is shipped.
# An `exec` cluster runs processes on its host with no scheduler, so it caps concurrency the same
# way a local one does.
local_procs(t::ClusterTarget) = t.procs > 0 ? t.procs : local_procs()

function ClusterTarget(host = ""; kind = :slurm, root = "", root_remote = root, payload = "",
                       parent = "", project = nothing,
                       resources = (; cpus = 1, mem = "2G", walltime = "01:00:00", partition = ""),
                       chunk = 16, account = "", qos = "", prologue = "", directives = "",
                       julia = "julia", procs = 0, mode = "0700", probe = 1)
    ClusterTarget(Symbol(kind), String(host), String(root), String(root_remote),
                  project === nothing ? "" : String(project), String(payload),
                  resources, Int(chunk), String(account), String(qos), String(prologue),
                  String(directives), String(parent), String(julia), Int(procs), String(mode),
                  Int(probe))
end

"A `ClusterTarget` on SLURM. The spelling notebooks and the docs use."
SlurmTarget(host = ""; kw...) = ClusterTarget(host; kind = :slurm, kw...)
"A `ClusterTarget` on PBS."
PbsTarget(host = ""; kw...) = ClusterTarget(host; kind = :pbs, kw...)

"""
    provision!(t) -> t

Put what a job needs on the far side and return a target naming it: the task environment built from
`parent`, and Slate's own runner.

Submit-time work, deliberately. It ships a project, instantiates an environment and precompiles it —
minutes on a cold cluster, and an authenticated connection either way. Reconciling a sweep, drawing
its card and opening the notebook it lives in all have to work without any of that.
"""
provision!(t::LocalTarget) = t
function provision!(t::ClusterTarget)
    proj = isempty(t.project) ?
        provision_remote_env!(t.host, t.root_remote, t.parent;
                              julia = t.julia, prologue = t.prologue) : t.project
    # The runner is Slate's own code and its location on the cluster is Slate's business, so it is
    # shipped rather than configured. Naming one is still allowed, for a site that stages it itself.
    pay = isempty(t.payload) ? provision_payload!(t.host, t.root_remote) : t.payload
    return ClusterTarget(t.kind, t.host, t.root, t.root_remote, proj, pay, t.resources, t.chunk,
                         t.account, t.qos, t.prologue, t.directives, t.parent, t.julia, t.procs,
                         t.mode, t.probe)
end

# Resources belong to the TARGET (a site's account, its partitions) but walltime, memory and cores
# are properties of the WORK, and vary sweep to sweep against the same cluster. So a sweep can
# override them without defining a second target.
with_resources(t::LocalTarget, res) = t          # nothing to schedule locally
with_resources(t::ClusterTarget, res) =
    res === nothing ? t :
    ClusterTarget(t.kind, t.host, t.root, t.root_remote, t.project, t.payload,
                  merge(t.resources, res), t.chunk, t.account, t.qos, t.prologue, t.directives,
                  t.parent, t.julia, t.procs, t.mode, t.probe)

# The scheduler settings a `#%% sweep` cell may carry on its header (engine.jl `cell_attrs`), e.g.
#
#     #%% sweep id=scan walltime=02:00:00 partition=gpu mem=16G
#
# These are the numbers you change WHILE a job is queued or after it was killed. Keeping them off
# the Julia source means adjusting one does not edit code — and because resources are deliberately
# not part of a sweep's key, raising a walltime RESUMES the sweep instead of discarding the units
# that already survived.
#
# A scheduler has ~40 options and every site adds requirements of its own, so a fixed list is a
# losing game: the previous one accepted `gpus=` and `nodes=`, parsed them, and then never emitted
# them — a cell asking for a GPU ran without one and returned plausible numbers computed on the
# wrong hardware. Silently dropping a setting is worse than not offering it.
#
# So the rule is PASS-THROUGH: any header `key=value` that is not one of Slate's own cell settings
# is a scheduler option, and becomes `--key=value` verbatim. `_` → `-`, since header keys must match
# `[A-Za-z][A-Za-z0-9_]*` (the tag editor's sanitiser) and no sbatch long option contains `_`. An
# option Slate has never heard of therefore works the day the site invents it, and a typo reaches
# the scheduler, which rejects the job loudly instead of running the wrong thing quietly.
#
# `_ATTR_RESOURCES` is what Slate KNOWS about, not what it permits: it types the counts, and it is
# the catalogue the cell's editor autocompletes against and warns outside of.
const _ATTR_RESOURCES = (:cpus, :mem, :mem_per_cpu, :walltime, :partition, :account, :qos,
                         :gpus, :gres, :nodes, :ntasks, :ntasks_per_node,
                         :constraint, :exclusive, :reservation, :nodelist, :exclude, :tmp,
                         :select)

# Which of those are counts rather than scheduler strings. Everything else passes through as
# WRITTEN: inventing a duration or size syntax here would only stand between the author and the
# scheduler's own documentation.
const _ATTR_COUNTS = (:cpus, :gpus, :nodes, :ntasks, :ntasks_per_node)

# Slate's OWN cell settings — the `key=value` tokens that mean something to the notebook rather than
# to the scheduler, and so must never be forwarded as a job option.
const _ATTR_OTHER = ("cluster", "data", "chunk", "id", "controls", "needs", "mutates", "region",
                     "script")

"Is this header key a scheduler option (rather than one of Slate's own cell settings)?"
is_sched_attr(k::AbstractString) = !(String(k) in _ATTR_OTHER)

# One line per catalogued option, for the cell's editor: what it does, in the terms the person
# setting it is thinking in. Lives here rather than in the front end so the list the UI suggests and
# the list Slate types cannot drift apart (`test_sweepcell.jl` asserts every key has one).
const _ATTR_HELP = Dict(
    :cpus            => "CPUs per unit",
    :mem             => "memory per unit, e.g. 4G",
    :mem_per_cpu     => "memory per CPU instead of per unit",
    :walltime        => "HH:MM:SS — the limit a unit is killed at",
    :partition       => "queue / partition name",
    :account         => "charge the work to this allocation",
    :qos             => "quality of service",
    :gpus            => "GPUs per unit",
    :gres            => "generic resource, e.g. gpu:v100:2",
    :nodes           => "nodes per job",
    :ntasks          => "tasks per job",
    :ntasks_per_node => "tasks on each node",
    :constraint      => "node features required, e.g. avx512",
    :exclusive       => "do not share the node — yes, or user/mcs/topo",
    :reservation     => "run inside a named reservation",
    :nodelist        => "run only on these nodes",
    :exclude         => "never run on these nodes",
    :tmp             => "local scratch required per node",
    :select          => "PBS only: the chunk statement verbatim, e.g. 2:ncpus=8:mem=16gb",
)

"""
    sched_options() -> Vector{NamedTuple}

The scheduler options Slate knows about: `(; key, flag, pbs, hint, count)` — the header spelling,
how each scheduler spells it, what it does, and whether it must be a number.

BOTH spellings, in one list, because the editor is opened before it knows which cluster the cell
names and because typing either spelling has to land on the same stored key — two catalogues would
be two chances for that to drift. An empty spelling means that scheduler has no way to say it, which
the editor shows rather than suggesting a setting whose only effect would be a rejected job.

A CATALOGUE, not a permitted set. The cell editor suggests these and warns outside them, but any
name is accepted and forwarded (`is_sched_attr`): a scheduler has far more options than are worth
naming, sites add their own, and a setting that is quietly dropped is worse than one nobody
suggested. Served to the front end so the two lists cannot drift.
"""
sched_options() = [(; key = String(k), flag = BatchLauncher.sbatch_flag(k),
                      pbs = BatchLauncher.pbs_flag(k),
                      hint = get(_ATTR_HELP, k, ""), count = k in _ATTR_COUNTS)
                   for k in _ATTR_RESOURCES]

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
    # No scheduler AND no host is this machine, which has a target of its own — it needs no ssh
    # session and prepares its environment directly.
    (a.kind == "exec" && isempty(a.host)) &&
        return LocalTarget(; a.root, a.parent, a.chunk, a.procs)
    return ClusterTarget(a.host; kind = Symbol(a.kind), a.root, a.root_remote, a.parent, a.payload,
                         a.chunk, a.account, a.qos, a.prologue, a.directives, a.resources, a.procs,
                         a.mode)
end

"""
    cluster_args(spec) -> NamedTuple

What a cluster definition MEANS, without building anything — for validating a definition or showing
what it resolves to.
"""
function cluster_args(spec::AbstractDict)
    get_(k, d = "") = String(get(spec, k, d))
    kind = lowercase(get_("kind", "slurm"))
    name = get_("name", "cluster")
    # `kind` names what SCHEDULES the work; `host` says where. `local` is the older spelling of
    # `exec` with no host, kept because a definition on disk uses it.
    kind == "local" && (kind = "exec")
    kind in ("slurm", "pbs", "exec") ||
        error("cluster `$name` has kind `$kind`; this build supports `slurm`, `pbs` and `exec` " *
              "(no scheduler — Slate runs the processes itself, here or on a host). " *
              "Kubernetes is a separate backend, not an option here.")
    root = get_("root")
    host = get_("host")
    # `exec` only: how many task processes at once, wherever it runs. 0 = follow the setting.
    procs = something(tryparse(Int, get_("procs", "0")), 0)
    # How private the store is on a machine you share. Private by default: a store holds results,
    # job output and the body's own source, and it lives on scratch where a home directory's
    # permissions do not reach. "" follows the site's umask, for a store meant to be shared.
    mode = get_("mode", "0700")
    isempty(mode) || occursin(r"^0?[0-7]{3}$", mode) ||
        error("cluster `$name` has mode `$mode`; use an octal directory mode such as \"0700\" " *
              "(private) or \"0750\" (your group may read), or \"\" to follow the site's umask")
    root_remote = get_("root_remote")
    # A cluster reached over ssh has ONE store, and it is the cluster's — `root` is for a local run,
    # or for the unusual case of a store this notebook has mounted. Requiring both was a hangover
    # from assuming a shared filesystem.
    # No host means everything is on THIS machine — including a scheduler whose client tools are
    # here, which is the case when Slate runs on the login node itself. The store is then local.
    if isempty(host)
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
    res = cluster_resources(spec)
    return (; kind, name, root, parent, chunk, payload, procs, mode,
              root_remote = isempty(root_remote) ? root : root_remote,
              host, account = get_("account"), qos = get_("qos"),
              prologue = get_("prologue"), directives = get_("directives"),
              resources = res === nothing ? NamedTuple() : res)
end

# Resolve the target a sweep cell asked for: an explicit one written in the cell wins, else the
# `cluster=` named on its header, else nothing to run on — which is worth an error naming the
# targets that ARE defined, because the usual cause is a typo, a rename, or opening a notebook on a
# machine that has never been told what `hpc` means. The name is the notebook's; what it resolves to
# belongs to the machine, so the error points at where the machine is configured.
const _WHERE_TARGETS = "the front page, under Remotes → Clusters"

function resolve_target(explicit, attrs::AbstractDict, clusters::AbstractDict)
    explicit === nothing || return explicit
    known() = join(sort!(collect(keys(clusters))), ", ")
    nm = String(get(attrs, "cluster", ""))
    if isempty(nm)
        isempty(clusters) &&
            error("@sweep: this cell has no cluster. Pick one from the ⚙ on the cell — or set one " *
                  "up first, on $_WHERE_TARGETS.")
        error("@sweep: this cell has no cluster. Pick one from the ⚙ on the cell. " *
              "This machine has: " * known())
    end
    spec = get(clusters, nm, nothing)
    spec === nothing &&
        error("@sweep: this machine has no cluster named `$nm`. " *
              (isempty(clusters) ? "It has none — set one up on $_WHERE_TARGETS." :
                                   "It has: " * known() * ". Add or rename one on $_WHERE_TARGETS.") *
              " (The notebook stores the name; each machine decides what it points at.)")
    return cluster(merge(Dict{String,Any}("name" => nm), spec))
end

# String → the type the JobSpec wants. Counts are integers; everything else is a scheduler string
# passed through as written (`mem=16G`, `walltime=02:00:00`), because inventing a duration syntax
# here would only stand between the author and the scheduler's own documentation.
function attr_resources(attrs::AbstractDict)
    res = Dict{Symbol,Any}()
    for (k, v) in attrs
        is_sched_attr(k) || continue
        s = Symbol(k)
        if s in _ATTR_COUNTS
            n = tryparse(Int, v)
            (n === nothing || n < 1) &&
                error("@sweep: `$k=$v` must be a positive integer")
            res[s] = n
        else
            res[s] = String(v)
        end
    end
    isempty(res) && return nothing
    return NamedTuple(res)
end

"""
    cluster_resources(spec) -> NamedTuple | nothing

The scheduler defaults a CLUSTER definition carries. Unlike a cell header this is a structured form
with known fields (`kind`, `root`, `payload`, …), so it reads a whitelist rather than passing
everything through — forwarding `root=/scratch/cas` to sbatch as an option would be nonsense. A site
option with no field of its own goes in the definition's `directives`.
"""
function cluster_resources(spec::AbstractDict)
    res = Dict{Symbol,Any}()
    for k in _ATTR_RESOURCES
        v = get(spec, String(k), nothing)
        (v === nothing || isempty(strip(String(v)))) && continue
        if k in _ATTR_COUNTS
            n = tryparse(Int, String(v))
            (n === nothing || n < 1) &&
                error("cluster: `$k=$v` must be a positive integer")
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

Whether the cell asked for its results to be stored ADDRESSABLY. Configuration rather than code: the
sweep body is identical whichever way this goes, and the choice is about the shape and size of what
comes out, which is a property of the run rather than of the code that produced it.
"""
# What a cell may say about how its units' results are stored. NOT part of the sweep key: storage is
# not what computed a result, so changing it must not orphan the units already landed.
#
#   auto    the shape decides — addressable when the value has such a form, whole otherwise
#   arrow   chunk row-shaped output even when it is small enough to ride the manifest
#   whole   one blob per unit, handed back exactly as returned
const _DATA_MODES = ("auto", "arrow", "whole")

function attr_lazy(attrs::AbstractDict)
    v = get(attrs, "data", nothing)
    v === nothing && return false
    s = lowercase(strip(String(v)))
    # `lazy`/`eager` were the old spellings and they are GONE rather than aliased. They named a
    # binary choice about one storage decision, which is the thing this replaced; keeping them
    # working would keep the idea alive in every notebook that still said it.
    s == "lazy"  && error("@sweep: `data=lazy` is now `data=auto` — the shape decides.")
    s == "eager" && error("@sweep: `data=eager` is now `data=whole`.")
    s in _DATA_MODES ||
        error("@sweep: `data=$v` on the cell header must be one of " * join(_DATA_MODES, ", "))
    return s in ("auto", "arrow")
end

"A `chunk=` header attribute, or `nothing`. How many units ride one scheduler job."
function attr_chunk(attrs::AbstractDict)
    v = get(attrs, "chunk", nothing)
    v === nothing && return nothing
    n = tryparse(Int, v)
    (n === nothing || n < 1) && error("@sweep: `chunk=$v` on the cell header must be a positive integer")
    return n
end

# How much of a sweep goes out before any of it has reported. Carried on the target because the
# card's poll reconciles without going back through `@sweep`, which is where the sweep set it.
sweep_policy(t::SweepTarget) = BatchSweep.FailurePolicy(; probe_chunks = t.probe)

# `probe=` is the SWEEP's call, not the cluster's: a header option describes the machine the work
# runs on, and how much of a grid to risk before checking is a property of the body.
with_probe(t::LocalTarget, n) = n === nothing ? t :
    LocalTarget(t.root, t.project, t.payload, t.chunk, t.procs, n)
with_probe(t::ClusterTarget, n) = n === nothing ? t :
    ClusterTarget(t.kind, t.host, t.root, t.root_remote, t.project, t.payload, t.resources, t.chunk,
                  t.account, t.qos, t.prologue, t.directives, t.parent, t.julia, t.procs, t.mode, n)

with_chunk(t::LocalTarget, n) = n === nothing ? t :
    LocalTarget(t.root, t.project, t.payload, n, t.procs, t.probe)
with_chunk(t::ClusterTarget, n) = n === nothing ? t :
    ClusterTarget(t.kind, t.host, t.root, t.root_remote, t.project, t.payload,
                  t.resources, n, t.account, t.qos, t.prologue, t.directives, t.parent, t.julia,
                  t.procs, t.mode, t.probe)

"The host a target authenticates to; empty for one that runs here."
target_host(::LocalTarget) = ""
target_host(t::ClusterTarget) = t.host

store_root(t::LocalTarget) = t.root
# The hub plans against the MIRROR for a remote cluster — a local directory holding a copy of the
# store's metadata. `root_remote` stays the job's view and never changes.
store_root(t::ClusterTarget) = plan_root(t)
# The store as the SCHEDULER sees it. Distinct from `store_root` because a job's output file is on
# the cluster's filesystem, under the path the job was given — reading it means naming that path,
# not the mirror the hub plans against.
job_root(t::LocalTarget) = t.root
job_root(t::ClusterTarget) = t.root_remote
chunk_size(t::LocalTarget) = t.chunk
chunk_size(t::ClusterTarget) = t.chunk

launcher_for(t::LocalTarget) = BatchLauncher.ExecLauncher(; maxproc = local_procs(t))
# The client tools run through the host's session, like everything else — the launcher is handed the
# runner rather than building its own ssh command. This is the ONE place a target's scheduler is
# consulted, which is what makes a third one a new `Launcher` and nothing else.
function launcher_for(t::ClusterTarget)
    # `exec` is not a scheduler — it is the absence of one, on a machine that is not this one. The
    # processes are Slate's to start, watch and kill, so the concurrency cap applies there exactly
    # as it does here; nothing else about the target changes.
    # `root` is `job_root`, not `store_root`: the reconciler hands every launcher the hub's mirror,
    # and this one's pid files are on the far side under the cluster's own path.
    t.kind === :exec &&
        return BatchLauncher.ExecLauncher(t.host; maxproc = local_procs(t), root = job_root(t),
                                          runner = (h, sc) -> run_there(h, sc))
    ctor = t.kind === :slurm ? BatchLauncher.SlurmLauncher :
           t.kind === :pbs   ? BatchLauncher.PbsLauncher :
           error("cluster: no launcher for scheduler `$(t.kind)`")
    return ctor(t.host; account = t.account, qos = t.qos, runner = (h, sc) -> run_there(h, sc))
end

# The umask that produces a directory mode. `0700` → `077`: what the mode does NOT grant. Empty
# mode means the site's own default, so no `umask` line is emitted at all.
store_umask(mode::AbstractString) = isempty(mode) ? "" :
    string(0o777 & ~parse(UInt16, mode; base = 8); base = 8, pad = 3)
store_umask(t::ClusterTarget) = store_umask(t.mode)
store_umask(::LocalTarget) = ""      # a local store sits under the user's own directories

specfn_for(t::LocalTarget) = (name, cs) -> BatchLauncher.JobSpec(name, cs;
    root = t.root, project = t.project, payload = t.payload)
# `reconcile!` calls this only when it has a job to submit, so provisioning here is what keeps it off
# the path that merely reads the store. Once per reconcile, not once per job.
function specfn_for(t::ClusterTarget)
    ready = Ref{Union{Nothing,ClusterTarget}}(nothing)
    return (name, cs) -> begin
        p = ready[] === nothing ? (ready[] = provision!(t)) : ready[]
        BatchLauncher.JobSpec(name, cs; root = p.root_remote, project = p.project,
                              payload = p.payload, resources = p.resources,
                              prologue = p.prologue, directives = p.directives,
                              umask = store_umask(p))
    end
end

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
# For a cluster the environment has usually not been built yet — and must not be, to answer this. So
# compute the name `provision_remote_env!` WILL give it, from the parent's fingerprint, here.
function env_key(t::ClusterTarget)
    isempty(t.project) || return basename(rstrip(t.project, '/'))
    isempty(t.parent) && return "env"
    return first(env_source_fingerprint(t.parent), 12)
end

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

# Whether a host fronts a scheduler at all — which decides what a region on it even means, and so
# which questions its configuration should ask.
Base.include(@__MODULE__, joinpath(@__DIR__, "scheduler.jl"))
# …over the connection a sweep already uses.
detect_scheduler(host::AbstractString) = SchedulerDetect.detect(s -> run_there(host, s))

# Holding a piece of the machine, rather than submitting work to it — what an INTERACTIVE session on
# a compute node needs. Included here because it speaks to the scheduler through the same target and
# the same connection a sweep does.
Base.include(@__MODULE__, joinpath(@__DIR__, "allocation.jl"))

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
    # How much this sweep in particular may hand back in one read (see `read_limit`). `:default`
    # follows the process-wide setting; set it to loosen or disable the guard for THIS sweep without
    # touching any other.
    read_limit::Any
end
ShardedResult(key, run, target, params, keys, plan, rows, telemetry, plot) =
    ShardedResult(key, run, target, params, keys, plan, rows, telemetry, plot, :default)

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
                  :results, :records, :summaries, :errors, :hosts, :bytes, :started, :dataset)

function Base.getproperty(r::ShardedResult, s::Symbol)
    s in fieldnames(ShardedResult) && return getfield(r, s)
    p, t = getfield(r, :plan), getfield(r, :telemetry)
    rows = getfield(r, :rows)
    s === :state      && return display_state(p, BatchSweep.is_started(store_root(getfield(r, :target)),
                                                                     getfield(r, :run)))
    s === :started      && return BatchSweep.is_started(store_root(getfield(r, :target)), getfield(r, :run))
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
    # THE view of what the sweep produced: every grid point, its parameters beside its output,
    # whether that output was chunked into the store or carried inline in the manifest. Built from
    # manifests alone, so asking for it — and asking it for its schema and size — reads none of the
    # data it describes.
    s === :dataset    && return _dataset_of(store_root(getfield(r, :target)),
                                            getfield(r, :params), getfield(r, :keys),
                                            getfield(r, :run), source_of(getfield(r, :target));
                                            limit = getfield(r, :read_limit))
    s === :results    && return [row for row in rows if row.status == "ok"]
    # What the units RETURNED, straight from the manifests. This is the accessor analysis should
    # reach for: it is the same cost at four units and four million, where `[row.value[] …]` is a
    # blob read per unit and a way to spell "all of it" by accident.
    s === :records    && return [row.record for row in rows if row.status == "ok"]
    # The charting figure — the same thing unless `summary =` derived one.
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
# Every unit the STORE has, keyed by shard key, from one directory listing.
#
# Store-wide rather than per-run on purpose. A shard key is a hash of the body and the parameter
# point and carries no chunk or run in it, so a pilot over four points and the full sweep over four
# thousand share keys and the second reuses the first's results. Folding only the run's own chunks
# made that reuse invisible and the full sweep recomputed what the pilot had already done.
# The results table needs the RECORDS, and it is store-wide because reuse is: a unit landed by a
# pilot belongs in the full sweep's table too. That makes it O(units) in memory, which is inherent
# to materialising a table of every unit, and it is why the poll path uses the status fold instead.
function store_rows(root::AbstractString)
    out = Dict{String,Any}()
    for (_, paths) in SlateTask.events_by_chunk(root)
        merge!(out, SlateTask.rows_of(root, paths))
    end
    return out
end

function sweep_bytes(root::AbstractString, sweep::AbstractString)
    total = 0
    evs = SlateTask.events_by_chunk(root)
    for c in (try; BatchSweep.sweep_chunks(root, sweep); catch; String[]; end)
        rows = SlateTask.rows_of(root, get(evs, c, String[]))
        for k in BatchSweep.chunk_shards(root, c)
            m = get(rows, k, nothing)
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
            sp = BatchSweep.spans(root, sw)
            # NOT `t`: that is the target, and everything after this loop still needs it.
            tel = BatchSweep.telemetry(root, sw; launcher = l, plan = p)
            push!(rows, (; sweep = sw, created,
                           # A store is shared: every cell that names this cluster writes runs into
                           # it, and so does every notebook pointing at the same root.
                           cell = BatchSweep.sweep_cell(root, sw),
                           notebook = BatchSweep.sweep_notebook(root, sw),
                           state = display_state(p, BatchSweep.is_started(root, sw)),
                           total = p.shards_total, done = p.shards_done,
                           ok = p.shards_ok, failed = p.shards_failed,
                           missing = p.shards_missing, blocked = p.blocked,
                           started = BatchSweep.is_started(root, sw),
                           rate = tel.rate_per_s, eta = tel.eta_s,
                           idle = BatchSweep.stalled_for(tel),
                           # One pass over the manifests for where it ran and when. `results` would
                           # answer the same and read every unit's VALUE to do it.
                           sp.hosts, started_at = sp.started, finished_at = sp.finished,
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
# Which notebook is evaluating, for attributing a run in a store several of them share. The DOCID,
# which is file-carried and survives a move or a rename — a session id would orphan every run the
# moment the notebook reopened. Empty outside a notebook, which is what a script or a test is.
function _ctx_docid()
    sctx = get(task_local_storage(), :slate_ctx, nothing)
    (sctx !== nothing && hasproperty(sctx, :docid)) && return String(sctx.docid)
    return ""
end

function _ctx_clusters()
    sctx = get(task_local_storage(), :slate_ctx, nothing)
    (sctx !== nothing && hasproperty(sctx, :clusters)) && return sctx.clusters
    return Dict{String,Dict{String,String}}()
end

function Base.show(io::IO, ::MIME"text/plain", s::ClusterStatus)
    println(io, "cluster ", s.name, " — ", get(s.spec, "kind", "?"),
            haskey(s.spec, "host") && !isempty(s.spec["host"]) ? " @ " * s.spec["host"] : "")
    # Name the STORE, and label the mirror as the shadow it is. Printing the local path against a
    # figure measured on the cluster invited exactly the wrong reading of both.
    host = String(get(s.spec, "host", ""))
    far = String(get(s.spec, "root_remote", ""))
    println(io, "   store   ", (isempty(host) || isempty(far)) ? s.root : host * ":" * far)
    # The gap between what the sweeps claim and what the store weighs is blobs nothing references
    # any more — a reset sweep, a re-keyed one. On a quota'd scratch that is the number worth
    # seeing. Only mentioned when it clears block-rounding, and never when dedup inverts it.
    claimed = sum(r.stored for r in s.sweeps; init = 0)
    loose = s.store.bytes - claimed
    println(io, "           ", _bytes(s.store.bytes), " in ", s.store.blobs, " blobs",
            (claimed > 0 && s.store.bytes > claimed * 11 ÷ 10) ?
                " · " * _bytes(loose) * " unreferenced" : "")
    (isempty(host) || isempty(far)) || println(io, "   mirror  ", s.root, "  (metadata only)")
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
# A ClusterTarget with no host runs its client tools here, so its store is here too. With a host the
# blobs are THERE, and reading them means byte ranges over ssh — `root_remote`, the path the host
# uses, not the mirror the hub plans against.
source_of(t::ClusterTarget) =
    isempty(t.host) ? LocalSource(t.root) : SshSource(t.host, t.root_remote)

# ── The store the hub plans against ──────────────────────────────────────────────────────────
# For a remote cluster this is the local MIRROR, not the cluster path: `plan`, `telemetry`,
# `results` and `status_payload` all walk manifests, and they go on doing that against a directory
# on this machine. What changes is that the directory is a copy, refreshed in one round trip.
#
# Cached per (host, root) so the mirror — and the ssh control socket behind it — is shared by every
# sweep pointed at the same cluster, rather than one per cell.
const _STORES = Dict{Tuple{String,String},RemoteStore}()
const _STORES_LOCK = ReentrantLock()

function remote_store(t::ClusterTarget)
    lock(_STORES_LOCK) do
        get!(_STORES, (t.host, t.root_remote)) do
            s = RemoteStore(t.host, t.root_remote; umask = store_umask(t))
            ensure_root!(s)
            s
        end
    end
end

"Where this hub reads and writes store METADATA. Local for a local target; the mirror for a cluster."
plan_root(t::LocalTarget) = t.root
plan_root(t::ClusterTarget) = isempty(t.host) ? t.root : remote_store(t).mirror

"Refresh the hub's view of a store before planning against it. No-op when the store is local."
sync_in!(::LocalTarget) = true
sync_in!(t::ClusterTarget) = isempty(t.host) ? true : pull_meta!(remote_store(t))

# Reconcile, and send back what it wrote IF it submitted. `jobs/` is hub-owned — the submission
# index and the attempt counts — and the store has to end up holding it: a fresh hub reads it to
# find work this one started, and the counts are supposed to outlive the hub that made them. But a
# card polls this on a timer, so the round trip is worth paying only when something changed. The
# attempt counts are the signal, because they move on exactly the submissions that went out.
# Whether this target can be reached at all. A sweep started against a cluster nobody has signed in to
# WAITS rather than failing: submitting is the only thing a sign-in gates, and the card already says
# what is missing. It goes out on the next poll after someone signs in.
_reachable(t::SweepTarget) = (h = target_host(t); isempty(h) || connected(h))

"""
    started_runs(root) -> Vector{String}

Runs in this store that were STARTED, from the markers alone. One directory read, no manifest
parsing — which is what lets a supervisor ask every store on the machine and pay nothing for the
ones with nothing going on.
"""
function started_runs(root::AbstractString)
    d = BatchSweep.jobs_dir(String(root))
    isdir(d) || return String[]
    return String[basename(f)[1:end-8] for f in readdir(d) if endswith(f, ".started")]
end

# When each cluster was last advanced, so a slow store cannot be asked again while the answer to the
# last question is still in the post.
const _ADVANCE_AT = Dict{String,Float64}()

"""
    advance_started!(; every = 30.0) -> Int

Release the next wave of every started, unsettled sweep this machine knows about, and return how
many were advanced.

A sweep goes out in waves: one chunk, then the rest once a unit has landed and the body is known to
work. Something has to release that second wave, and until now the only thing that did was an open
sweep card — so closing the tab left the rest of a grid unsubmitted, indefinitely. Clusters are
registered per MACHINE rather than per notebook, which is what lets this run with nothing open.

Throttled per cluster, and skipped entirely for a store with no started run: an idle machine costs
one `readdir` per cluster per tick and never touches the network.
"""
# The cluster registry and the remote log live in the hub's module. Looked up at call time because
# this file also loads on a worker, which has neither.
_hub_clusters() = isdefined(P, :clusters_all) ? P.clusters_all() : Dict{String,Any}[]
_hub_log(msg::AbstractString) = (isdefined(P, :_rlog) && P._rlog(msg); nothing)

function advance_started!(; every::Real = 30.0)
    n = 0
    for c in _hub_clusters()
        name = String(get(c, "name", ""))
        isempty(name) && continue
        spec = Dict{String,String}(String(k) => String(v) for (k, v) in c)
        t = try; cluster(spec); catch; continue; end      # a definition we cannot build is not ours to fix
        root = store_root(t)
        runs = started_runs(root)
        isempty(runs) && continue
        time() - get(_ADVANCE_AT, name, 0.0) < every && continue
        _ADVANCE_AT[name] = time()
        # A cluster nobody has signed in to WAITS, exactly as the card's poll does — submitting is
        # the only thing a sign-in gates, and it goes out on the next tick after one lands.
        _reachable(t) || continue
        try; sync_in!(t); catch; continue; end
        # Fold the MIRROR's log. A pull merges and never deletes, so a store compacted over there
        # leaves this side holding the originals; folding here is what keeps the mirror from growing
        # for the life of the store. Local files only, and never required for correctness.
        try; SlateTask.compact_events!(root); BatchSweep.forget_fold!(root); catch; end
        l = launcher_for(t)
        for run in runs
            # Clear markers with no run behind them; the store was synced in above.
            if MemoStore.read_manifest(root, run) === nothing
                BatchSweep.stop!(root, run)
                _hub_log("supervisor: $(name)/$(run) has no descriptor — dropped its started marker")
                continue
            end
            try
                p = reconcile_and_sync!(t, run, l; submit = true, failure_policy = sweep_policy(t))
                BatchSweep.is_settled(p) || (n += 1)
            catch e
                _hub_log("supervisor: advancing $(name)/$(run) failed: " * first(sprint(showerror, e), 160))
            end
        end
    end
    return n
end

# Runs whose descriptors this process has sent. The cell pushes them, but a cluster that wants a
# sign-in is unreachable until someone signs in, and that is usually AFTER the cell has run: the
# push is a no-op, nothing is submitted, and the card submits later against a store that never got
# them. The job then starts and dies on the far side looking for its own chunk.
const _DESC_SENT = Set{Tuple{String,String}}()
const _DESC_LOCK = ReentrantLock()

# Idempotent and content-addressed, so the repeat costs a manifest rewrite and no blob movement.
function _ensure_descriptors!(t::SweepTarget, run::AbstractString)
    isempty(target_host(t)) && return true
    k = (store_root(t), String(run))
    lock(_DESC_LOCK) do; k in _DESC_SENT; end && return true
    sync_out!(t) || return false
    lock(_DESC_LOCK) do; push!(_DESC_SENT, k); end
    return true
end

_descriptors_sent!(t::SweepTarget, run::AbstractString) =
    lock(_DESC_LOCK) do; push!(_DESC_SENT, (store_root(t), String(run))); end

function reconcile_and_sync!(target::SweepTarget, run::AbstractString, launcher;
                             submit::Bool = false, kw...)
    if submit && !_ensure_descriptors!(target, run)
        error("could not send sweep $(run)'s descriptors to " *
              "$(target_host(target)):$(job_root(target)) — nothing was submitted")
    end
    root = store_root(target)
    before = BatchSweep.read_attempts(root)
    p = BatchSweep.reconcile!(root, run, launcher, specfn_for(target); submit, kw...)
    BatchSweep.read_attempts(root) == before || sync_out!(target; dirs = ("jobs",))
    return p
end

# A change to `jobs/` is only real once it has been pushed. `sync_in!` REPLACES the mirror's copy
# from the store, so a poll landing between the change and the push restores what was just removed,
# and the push then sends it back. Holding the store's sync lock across both keeps them together.
_with_store_lock(f, ::LocalTarget) = f()
_with_store_lock(f, t::ClusterTarget) =
    isempty(t.host) ? f() : with_store_lock(f, remote_store(t).mirror)

"Send what the hub has written — descriptors, their blobs, markers — to the store. `dirs` narrows
it to part of that, for the callers that have just touched one thing."
sync_out!(::LocalTarget; dirs = nothing) = true
sync_out!(t::ClusterTarget; dirs = nothing) =
    isempty(t.host) ? true :
    (dirs === nothing ? push_meta!(remote_store(t)) : push_meta!(remote_store(t); dirs))

"""
    forget_results!(target, keys)

Drop these units' results for good — from the hub's view AND from the store. Deleting only locally
would be undone by the next sync, which reads the store as the truth; that is right for everything
except a deletion someone asked for.
"""
# Forgetting a unit has to reach the LOG, not just the mirror. The log is immutable, so removal is
# said in a new event per chunk rather than by editing the events that recorded the unit. A removal
# that only dropped the local record brought the result back on the next sync, which is how a reset
# came to report four units done out of three.
function forget_results!(t::SweepTarget, keys)
    root = store_root(t)
    want = Set(String.(keys))
    isempty(want) && return 0
    evs = SlateTask.events_by_chunk(root)
    n = 0
    written = String[]
    for (c, paths) in evs
        gone = String[k for k in Base.keys(SlateTask.rows_of(root, paths)) if k in want]
        isempty(gone) && continue
        push!(written, SlateTask.write_event!(root, c, Dict{String,Any}[]; dropped = gone))
        n += length(gone)
    end
    # The tombstones are the hub's and have to cross, or the store keeps answering with the units
    # this just forgot.
    t isa ClusterTarget && !isempty(t.host) && !isempty(written) &&
        sync_out!(t; dirs = ("events",))
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
    # The SAME session as everything else, so a slice costs a round trip rather than a round trip
    # plus a handshake, a key exchange and — on a gated cluster — a prompt. An empty host runs it
    # here, which is what makes the byte plumbing exercisable without a cluster.
    ok, data = run_io(String(s.host), script, nothing)
    ok || error("reading $(len) bytes of $(blob) from $(s.host) failed")
    out = IOBuffer(); write(out, data)
    b = take!(out)
    length(b) == len ||
        error("short read from $(s.host): asked $(len) bytes at $(offset), got $(length(b))")
    return b
end

# A chunk fetched from a store the hub cannot see, kept so a second look at the same rows is free.
# Content-addressed, so the cache can never be stale: a blob's name IS its bytes.
_blob_cache_dir() = joinpath(SlateHome.cache_home(), "remote-blobs")

# ── Bounding the cache ───────────────────────────────────────────────────────────────────────
# This is a PURE cache, which is what makes it simple: every file is content-addressed, nothing
# references it, and losing one costs a re-fetch of a few hundred kilobytes. So it wants a plain
# LRU with a size cap, not the refcounting and pinning `MemoStore.gc` needs for a store whose
# entries are the only copy of what they hold.
#
# It needs a bound at all because `fetch` on an ARTIFACT lands here too, and an artifact is the
# unbounded case by definition — weights, a checkpoint, a rendered video. A cache that only ever
# held chunk-sized pieces could be ignored; one that holds whatever a unit chose to leave behind
# cannot.

"Bytes the remote-blob cache may hold. Free disk / 16, clamped, or `KAIMONSLATE_BLOB_CAP_GB`."
function _default_blob_cap()::Int
    free = try; Base.diskstat(dirname(_blob_cache_dir())).available; catch; 0; end
    gb = 1024^3
    # A sixteenth rather than the memo store's quarter, and a lower ceiling: re-fetching costs
    # seconds on the connection that is already open, where recomputing a memo entry can cost hours.
    return free <= 0 ? 4gb : clamp(round(Int, free ÷ 16), gb, 8gb)
end
const _BLOB_CAP = Ref{Int}(0)
blob_cap() = (_BLOB_CAP[] > 0 ? _BLOB_CAP[] : (_BLOB_CAP[] =
    (v = tryparse(Float64, get(ENV, "KAIMONSLATE_BLOB_CAP_GB", "")); v !== nothing && v > 0 ?
        round(Int, v * 1024^3) : _default_blob_cap())))

# Sweeping walks the directory, so it must not run per read. Bytes fetched since the last sweep are
# counted and one is due past an eighth of the cap — the walk is amortised over roughly that much
# traffic, whatever size the pieces happen to be.
const _BLOB_FETCHED = Ref{Int}(0)

"""
    trim_blob_cache!(dir = _blob_cache_dir(); cap, grace = 300.0) -> Int

Evict least-recently-used entries until the cache fits `cap`, returning the bytes freed. `grace`
(seconds) covers two races at once: a `.part.` file another process is still writing, and an entry
this process has just returned to a caller that is about to mmap it.
"""
function trim_blob_cache!(dir::AbstractString = _blob_cache_dir();
                          cap::Integer = blob_cap(), grace::Real = 300.0)
    isdir(dir) || return 0
    now = time()
    live = Tuple{String,Float64,Int}[]
    total = 0
    for f in readdir(dir; join = true)
        isfile(f) || continue
        mt, sz = try; (Float64(mtime(f)), Int(filesize(f))); catch; continue; end
        if occursin(".part.", basename(f))
            # Litter from a fetch that died. Past the grace window nothing is still writing it.
            now - mt > grace && try; rm(f; force = true); catch; end
            continue
        end
        total += sz
        now - mt > grace && push!(live, (f, mt, sz))     # young entries are counted, never candidates
    end
    total <= cap && return 0
    sort!(live; by = x -> x[2])                          # least recently used first
    freed = 0
    for (f, _, sz) in live
        total - freed <= cap && break
        try; rm(f; force = true); freed += sz; catch; end
    end
    return freed
end

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
    if isfile(p) && filesize(p) == nbytes
        try; touch(p); catch; end         # mtime is the recency the trim sorts on, so a hit refreshes it
        return p
    end
    nbytes > 0 || error("cannot fetch blob $(blob): its size is not recorded")
    tmp = p * ".part.$(getpid())"
    try
        write(tmp, read_range(s, blob, 0, nbytes))
        mv(tmp, p; force = true)          # atomic: a partial fetch never lands under the real name
    catch
        rm(tmp; force = true); rethrow()
    end
    # Trim AFTER the fetch, and never on the hot path more often than the cap's eighth. The entry
    # just written is inside the grace window, so this cannot delete what it is about to return.
    _BLOB_FETCHED[] += nbytes
    if _BLOB_FETCHED[] > blob_cap() ÷ 8
        _BLOB_FETCHED[] = 0
        try; trim_blob_cache!(dir); catch; end     # best-effort: a full cache is not a failed read
    end
    return p
end

# What a unit's facts are before it has run. Its own once it has.
const _NOFACTS = (; status = "", ms = 0.0, ran_on = "", at = missing)

"""
    DatasetPart

One unit's contribution to a dataset: its rows, and the parameters and facts that produced them.

`backend` is where the rows come from, and it is the ONLY thing the read path branches on — in one
place, `part_rows`:

  - `:indexed` — chunked Arrow, a raw array, or an adopted file's group, read through the stored index
  - `:inline` — the rows rode the manifest record, because they were small enough to
  - `:none` — no addressable rows: the value was stored whole, the unit failed, or it has not run

That split is about STORAGE. A reader never has to know which one they got, and never has to pick an
accessor by it.
"""
struct DatasetPart
    root::String
    backend::Symbol
    index::Dict{String,Any}
    params::Any
    facts::NamedTuple   # status, ms, ran_on, at — one per UNIT, however many rows it produced
    rows::Int
    bytes::Int
    label::String
    src::Any            # LocalSource | SshSource — where this part's bytes are read from
end
DatasetPart(root, index, params, rows, bytes, label = "", src = LocalSource(root)) =
    DatasetPart(root, :indexed, index, params, _NOFACTS, rows, bytes, label, src)

"""
    Dataset

A sweep's output, addressable and unmoved, and the one view of it. Every grid point is a part:
whatever it returned, carrying the parameters that produced it. Rows concatenate across units into
one row space; arrays stay separate parts, since output of differing shape has no single meaning
stacked.

    ds                      # schema, parts, rows, size — no I/O
    ds[1:1000]              # a bounded slice
    ds[1:1000, (:t, :e)]    # …and only these columns
    Sweep.scan(ds; between = (:e, 3, Inf), where = r -> r.ok, limit = 10_000)

A unit that returned one row contributes one; a unit that returned many contributes all of them; a
unit that has not landed contributes one row of `missing`, so the holes are where the work still is.
Whether the rows were chunked into the store or carried inline in the manifest is storage, and it
does not reach the reader.

`status`, `ms`, `ran_on` and `at` are off the default projection, because on a unit that produced
many rows they repeat identically down the whole block. Name them in `select` to get them:

    ds[1:10, (:snr, :status, :ms)]

A sweep of ADOPTED FILES is a `:group` — a namespace rather than one shape, because a NetCDF or
HDF5 file holds several named variables. Picking one gives back an ordinary dataset, so nothing
past that point is special:

    keys(ds)                # the variable names
    ds[:sst][1]             # part 1 of the `sst` variable, then slice it
"""
struct Dataset
    kind::Symbol                  # :table | :array | :group
    parts::Vector{DatasetPart}
    pnames::Vector{Symbol}        # parameter columns — constant within each part
    columns::Vector{String}       # value columns, union over parts in first-seen order
    types::Vector{String}
    starts::Vector{Int}           # cumulative first global row of each part
    whole::Int                    # landed units with no addressable rows at all
    whole_why::String             # …and why: "shape" | "eager" | "arrow" | ""
    label::String                 # the sweep it came from, for transfer accounting
    purged::Bool                  # the index survived, the bytes did not
    limit::Any                    # this sweep's read guard; `:default` follows `read_limit()`
end

# The per-unit facts, as columns. Off the default projection; `select` reaches them by name.
const _FACT_NAMES = (:status, :ms, :ran_on, :at)

# The name a value column comes back under. A returned field that collides with a parameter keeps
# BOTH rather than overwriting, so it is suffixed. One rule, in one place, because `scan` has to
# name the same columns `load` produces.
_value_name(ds, c) = Symbol(c) in ds.pnames ? Symbol(String(c), "_result") : Symbol(c)

function Dataset(kind::Symbol, parts::Vector{DatasetPart}, whole::Integer = 0,
                 label::AbstractString = "", purged::Bool = false,
                 whole_why::AbstractString = ""; limit = :default)
    pnames = Symbol[]
    for p in parts
        p.params isa NamedTuple || continue
        for k in keys(p.params); k in pnames || push!(pnames, k); end
    end
    # The union over parts in first-seen order, not the first part's alone: a body with a branch can
    # report different fields per point, and taking one part's schema would drop the rest silently.
    cols = String[]; typs = String[]
    for p in parts, (c, t) in zip(get(p.index, "columns", String[]), get(p.index, "types", String[]))
        String(c) in cols || (push!(cols, String(c)); push!(typs, String(t)))
    end
    starts = Int[]; at = 1
    for p in parts; push!(starts, at); at += p.rows; end
    return Dataset(kind, parts, pnames, cols, typs, starts, Int(whole), String(whole_why),
                   String(label), purged, limit)
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

_ds_kind(d::AbstractDict) = (k = String(get(d, "kind", "table"));
                             k == "array" ? :array : k == "group" ? :group : :table)

# One variable's entry in a group index, or `nothing`.
_group_var(index::AbstractDict, name::AbstractString) =
    for v in get(index, "vars", Any[])
        v isa AbstractDict && String(get(v, "name", "")) == name && return v
    end

"Has this part's data actually survived? A remembered index can outlive the bytes it describes."
function part_present(p::DatasetPart)
    # A group holds no bytes of its own — its variables do. Probe the first, for the same reason
    # only one chunk is probed below: this answers "was the store purged", not "is every blob here".
    idx = _ds_kind(p.index) === :group ?
          (vs = get(p.index, "vars", Any[]); isempty(vs) ? p.index : vs[1]["index"]) : p.index
    blobs = String[]
    if String(get(idx, "kind", "")) == "array"
        push!(blobs, String(idx["blob"]))
    else
        cs = get(idx, "chunks", Any[])
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

# A unit that returned a bare number has no field name to use, so its column is called this.
const _TABLE_SCALAR = :result

# A record small enough to ride the manifest IS rows, and `_summarize` carries whole vectors — so a
# unit returning `(; i = 1:5, v = …)` is five rows that happened to be stored inline, not one row
# holding two vectors. Reading the storage as though it named the shape gave that unit's entire
# output a single row.
#
# `nothing` when there is nothing to make rows out of, which is what puts a unit on the `:none` path.
function _inline_index(rec)
    rec === nothing && return nothing
    nt = rec isa NamedTuple ? rec : NamedTuple{(_TABLE_SCALAR,)}((rec,))
    isempty(nt) && return nothing
    vals = values(nt)
    n = all(v -> v isa AbstractVector, vals) ? length(first(vals)) : 0
    (n > 0 && all(v -> length(v) == n, vals)) || (n = 0)
    names = String[String(k) for k in Base.keys(nt)]
    # Narrowed, so a one-row-per-unit sweep's schema reads `Float64` rather than `Any`.
    cols = Dict{String,Any}(nm => identity.(n > 0 ? collect(getproperty(nt, Symbol(nm))) :
                                                    Any[getproperty(nt, Symbol(nm))])
                            for nm in names)
    return Dict{String,Any}("kind" => "table", "rows" => max(n, 1), "bytes" => 0,
                            "columns" => names,
                            "types" => String[string(eltype(cols[nm])) for nm in names],
                            "cols" => cols)
end

# Assembled from the shard manifests: one part per GRID POINT, in grid order, whatever that point
# produced. A partial sweep gives a partial dataset rather than an error — the same property that
# lets the rest of the fabric be watched while it runs.
function _dataset_of(root, params, keys, label = "", src = LocalSource(root); limit = :default)
    parts = DatasetPart[]
    kind = :table
    whole = 0
    # Why the ones with no rows have none. The unit recorded it; the strongest reason wins, because
    # a shape with nothing to chunk is not fixed by anything the reader can do, while the other two
    # are. Empty for a unit that ran before this was recorded.
    whys = Set{String}()
    rows_ = store_rows(root)
    for (prm, k) in zip(params, keys)
        m = get(rows_, k, nothing)
        facts = m === nothing ? _NOFACTS :
                (; status = String(get(m, "status", "")),
                   ms = Float64(get(m, "ms", 0.0)),
                   ran_on = String(get(m, "ran_on", "")),
                   # In the READER's clock, like every other time a sweep prints. A manifest records
                   # unix time, which is UTC, and the cluster that wrote it may be in a third zone
                   # again — a raw conversion put two views hours apart while naming one event.
                   at = (t = Int(get(m, "created", 0));
                         t == 0 ? missing : Dates.unix2datetime(t) + _localoffset()))
        ok = m !== nothing && facts.status == "ok"
        idx = ok ? get(m, "dataset", nothing) : nothing
        if idx isa AbstractDict
            d = Dict{String,Any}(String(kk) => vv for (kk, vv) in idx)
            kind = _ds_kind(d)
            push!(parts, DatasetPart(String(root), :indexed, d, prm, facts,
                                     Int(get(d, "rows", 0)), Int(get(d, "bytes", 0)),
                                     String(label), src))
        elseif (inl = ok ? _inline_index(_record_of(m)) : nothing) !== nothing
            push!(parts, DatasetPart(String(root), :inline, inl, prm, facts,
                                     Int(inl["rows"]), 0, String(label), src))
        else
            # No addressable rows: stored whole, failed, or not run. Still a part, so the grid keeps
            # its shape and a hole sits exactly where the work is.
            ok && (whole += 1; push!(whys, String(get(m, "whole", ""))))
            push!(parts, DatasetPart(String(root), :none, Dict{String,Any}(), prm, facts,
                                     1, 0, String(label), src))
        end
    end
    # An array, or an adopted file's namespace, has no row space — so the placeholders that keep a
    # table's holes visible mean nothing there. Those datasets are their landed parts and no more.
    kind === :table || filter!(p -> p.backend === :indexed, parts)
    # The store had nothing to say. Either this sweep never ran, or its scratch has been purged and
    # the manifests went with it — and the difference matters, because in the second case we still
    # know exactly what the dataset was.
    if !any(p -> p.backend !== :none, parts) && whole == 0 && !isempty(label)
        remembered = recall_index(label)
        if remembered !== nothing
            kind = _ds_kind(remembered)
            # What the run HELD, in place of the placeholders standing in for it.
            empty!(parts)
            for pd in get(remembered, "parts", Any[])
                pd isa AbstractDict || continue
                idx = Dict{String,Any}(String(k) => v for (k, v) in get(pd, "index", Dict()))
                push!(parts, DatasetPart(String(root), idx, get(pd, "params", ""),
                                         Int(get(pd, "rows", 0)), Int(get(pd, "bytes", 0)),
                                         String(label), src))
            end
            # One probe, not one per chunk: if the first blob is gone the store was purged.
            gone = !isempty(parts) && !part_present(parts[1])
            return Dataset(kind, parts, whole, label, gone; limit = limit)
        end
    end
    # Only the INDEXED parts are worth outliving the store: inline rows live in the manifests, which
    # the purge takes with the blobs, and a placeholder describes nothing.
    remember_index!(label, root, filter(p -> p.backend === :indexed, parts), kind)
    why = "shape" in whys ? "shape" : "arrow" in whys ? "arrow" : "eager" in whys ? "eager" : ""
    return Dataset(kind, parts, whole, label, false, why; limit = limit)
end

Base.length(ds::Dataset) = isempty(ds.parts) ? 0 : ds.starts[end] + ds.parts[end].rows - 1
nparts(ds::Dataset) = length(ds.parts)
databytes(ds::Dataset) = sum(p -> p.bytes, ds.parts; init = 0)

function Base.show(io::IO, ::MIME"text/plain", ds::Dataset)
    n = length(ds)
    # Two different absences: a part with nothing to SHOW (it landed, but its value has no rows) is
    # not a part that has not RUN, and calling both "not landed" reported finished work as missing.
    shown = count(p -> p.backend !== :none, ds.parts)
    pending = ds.purged ? 0 : count(p -> isempty(p.facts.status), ds.parts)
    println(io, "Dataset — ", nparts(ds), " part", nparts(ds) == 1 ? "" : "s", ", ",
            ds.kind === :table ? "$(n) rows" :
            ds.kind === :array ? "$(n) elements" :
            "$(length(get(isempty(ds.parts) ? Dict() : ds.parts[1].index, "vars", Any[]))) variables",
            ", ", _bytes(databytes(ds)),
            (ds.kind === :table && pending > 0) ? " · $(pending) still to run" : "")
    if shown == 0
        # NOT unconditionally "nothing has landed yet": units may well have landed with nothing
        # addressable to show, which is a different fact with a different answer. `ds.whole` says so.
        ds.whole == 0 && println(io, "   nothing has landed yet")
    elseif ds.kind === :group
        for v in get(ds.parts[1].index, "vars", Any[])
            d = get(v, "dims", String[])
            shape = get(v["index"], "dims", Int[])
            println(io, "   ", rpad(String(v["name"]), 18),
                    isempty(shape) ? "$(get(v["index"], "rows", 0)) rows" :
                    join(shape, "×") * " " * String(get(v["index"], "eltype", "")),
                    isempty(d) ? "" : "  (" * join(d, ", ") * ")")
        end
        for s in get(ds.parts[1].index, "skipped", Any[])
            println(io, "   ", rpad(String(s["name"]), 18), "— not stored: ", String(s["why"]))
        end
        println(io, "   from ", String(get(ds.parts[1].index, "source", "")),
                " · keys(ds) for the names · ds[:name] for one variable")
    elseif ds.kind === :table
        for p in ds.pnames
            println(io, "   ", rpad(String(p), 18), "parameter")
        end
        for (c, t) in zip(ds.columns, ds.types)
            println(io, "   ", rpad(c, 18), t)
        end
        # The value columns cannot appear before the first unit reports: nothing until then knows
        # what they are called. Saying so beats a dataset that looks like it holds only parameters.
        isempty(ds.columns) &&
            println(io, "   (no value columns yet — no unit has said what they are called)")
        println(io, "   ds[1:1000] for rows · Sweep.scan(ds; …) to filter · ",
                "Sweep.query_cost(ds) to price it")
    else
        d = get(ds.parts[1].index, "dims", Int[])
        println(io, "   each part ", join(d, "×"), " ", String(get(ds.parts[1].index, "eltype", "")))
        println(io, "   ds[k] for part k · part[i…] to slice it")
    end
    # Units that finished before the cell asked for addressable storage still hold their results;
    # they just cannot be sliced. Saying so beats a dataset that is quietly missing most of itself.
    ds.purged && println(io, "   ⚠ the data is gone — this store was purged. The index is kept, so ",
                         "the schema and counts above are what it HELD; re-run the sweep to rebuild it.")
    # What to do about it depends entirely on WHY, and one message for three situations gave the
    # wrong answer twice. "Reset to re-store" is right for a unit that ran before the cell asked;
    # for a value with no addressable form it discards good units and changes nothing.
    if ds.whole > 0
        n = string(ds.whole, " finished unit", ds.whole == 1 ? "" : "s")
        println(io, "   ",
            ds.whole_why == "shape" ?
                string("ℹ ", n, " returned something with no row or array form, too large to ",
                       "record inline — so it is here as a hole. `row.value[]` fetches one.") :
            ds.whole_why == "arrow" ?
                string("⚠ ", n, " are column-shaped but Arrow was not available where they ran, ",
                       "so they stored whole. Add Arrow to the task environment, then reset.") :
            ds.whole_why == "eager" ?
                string("⚠ ", n, " could be stored addressably but the cell did not ask — ",
                       "add `data=auto` to its header, then reset the sweep to re-store.") :
                string("⚠ ", n, " stored whole and not in this view — reset the sweep to re-store."))
    end
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

# ── How much a single read may bring back ─────────────────────────────────────────────────────
# BYTES, not rows, because bytes are what hurt: a million rows of two numbers is a few tens of MB
# and a million rows of two hundred columns is not. The figure is free — `query_cost` already
# computes it off the index, before anything is read — so this refuses BEFORE the transfer rather
# than during it.
#
# A guard, not a law. It exists so that `DataFrame(ds)` on a sweep that turns out to be terabytes
# stops and says so instead of quietly filling memory. Anyone who means it says so and it gets out
# of the way, at whichever scope suits: a setting for this session, or one for a single sweep.
const _READ_LIMIT = Ref{Any}(512 * 1024^2)

"""
    read_limit() -> Int | Nothing
    read_limit!(bytes) -> bytes

The most any ONE read may bring back, in bytes, for this session. `nothing` turns the guard off.

    Sweep.read_limit!(4 * 1024^3)     # this session will hand back up to 4 GB at a time
    Sweep.read_limit!(nothing)        # …or as much as is asked for, on my head be it

A single sweep can differ from the session: `r.read_limit = nothing` frees that one and leaves
every other guarded. A `max_bytes` argument to `load` outranks both, since it is the most specific
statement of intent there is.

Only reads that touch the STORE are counted. Rows carried in a manifest cost nothing to hand over
and are never refused.
"""
read_limit() = _READ_LIMIT[]
read_limit!(bytes) = (_READ_LIMIT[] = bytes === nothing ? nothing : Int(bytes); bytes)

# `:default` at either level means "ask the level above". The result's setting wins over the
# session's, which is what makes loosening one sweep a local act.
_effective_limit(x) = x === :default ? _READ_LIMIT[] : x

"""
    ds[rows]            -> NamedTuple of columns
    ds[rows, columns]   -> …only those columns

Read a bounded row range. Only the chunks covering `rows` are opened, and only the columns named.
"""
Base.getindex(ds::Dataset, rows::AbstractUnitRange, cols = nothing) = load(ds, rows; select = cols)

"""
    part_rows(p, rows; select = nothing) -> NamedTuple of columns

One part's own rows. The ONLY place a dataset's storage backend is visible — everything above this
works in rows and column names.
"""
function part_rows(p::DatasetPart, rows::AbstractUnitRange; select = nothing)
    p.backend === :indexed &&
        return SlateTask.dataset_rows(p.root, p.index, rows; select = select,
                                      blobpath = (h, n) -> blob_file(p.src, h, n))
    p.backend === :inline || return NamedTuple()
    cols = p.index["cols"]
    want = select === nothing ? String[String(c) for c in p.index["columns"]] :
           String[String(s) for s in select if haskey(cols, String(s))]
    return NamedTuple{Tuple(Symbol.(want))}(Tuple(cols[c][rows] for c in want))
end

"""
    load(ds, rows; select = nothing, max_rows = DATASET_ROW_CAP) -> NamedTuple of columns

The read behind `ds[rows]`, with the cap exposed. Raising `max_rows` is how you ask for more than a
look — deliberately, at one call site, with the number written down.
"""
function load(ds::Dataset, rows::AbstractUnitRange; select = nothing,
              max_rows::Integer = DATASET_ROW_CAP, max_bytes = :default, record::Bool = true)
    ds.purged && error("this dataset's data has been purged from the store — the index survived, " *
                       "so the schema and counts are still readable, but the bytes are gone. " *
                       "Re-run the sweep to rebuild it.")
    ds.kind === :table ||
        error(ds.kind === :group ?
              "this dataset holds named variables, not one row space — `ds[:name]` picks one " *
              "(`keys(ds)` lists them), and that is what you read rows or elements from" :
              "this dataset holds arrays, not rows — `ds[k]` for part k, then slice that part")
    n = length(ds)
    (first(rows) >= 1 && last(rows) <= n) ||
        throw(BoundsError("rows $(rows) outside 1:$(n)"))
    length(rows) <= max_rows ||
        error("$(length(rows)) rows is over the $(max_rows)-row slice cap — narrow the range, " *
              "use `Sweep.scan(ds; limit = …)` to stream a filtered subset, or raise it deliberately " *
              "with `Sweep.load(ds, rows; max_rows = …)`")
    want = select === nothing ? nothing : Symbol[Symbol(s) for s in select]
    if want !== nothing
        known = Set{Symbol}([ds.pnames; Symbol.(ds.columns); collect(_FACT_NAMES)])
        bad = Symbol[w for w in want if !(w in known)]
        isempty(bad) ||
            error("no column " * join(bad, ", ") * " here — this dataset has " *
                  join([String.(ds.pnames); ds.columns], ", ") *
                  ", and the facts " * join(String.(_FACT_NAMES), ", "))
    end
    pwant = want === nothing ? ds.pnames : Symbol[k for k in ds.pnames if k in want]
    vwant = want === nothing ? Symbol.(ds.columns) :
            Symbol[Symbol(c) for c in ds.columns if Symbol(c) in want]
    # The facts repeat down a unit's whole block, so they are off the projection until named.
    fwant = want === nothing ? Symbol[] : Symbol[k for k in _FACT_NAMES if k in want]

    # Priced BEFORE anything is read, off the index alone, so a read too big to want is refused
    # rather than half-made. Only STORED bytes count: rows that rode a manifest are already here.
    span = _ds_span(ds, rows)
    cap = _effective_limit(max_bytes === :default ? ds.limit : max_bytes)
    if cap !== nothing
        want = 0
        for (i, local_rows) in span
            p = ds.parts[i]
            p.backend === :indexed || continue
            for (pos, _, _, _) in SlateTask.table_chunks(p.index, local_rows)
                want += Int(p.index["chunks"][pos]["bytes"])
            end
        end
        want <= cap || error(
            "this read would bring back $(_bytes(want)), over the $(_bytes(cap)) limit for one " *
            "read — narrow the range, project fewer columns, use `Sweep.scan(ds; …)` to filter it " *
            "down, or lift the guard: `Sweep.load(ds, rows; max_bytes = …)` for this call, " *
            "`r.read_limit = …` for this sweep, `Sweep.read_limit!(…)` for the session " *
            "(`nothing` anywhere means no limit)")
    end

    blocks = Any[]
    bytes = 0; opened = 0; t0 = time()
    for (i, local_rows) in span
        p = ds.parts[i]
        # Charged BEFORE the read, off the index: these are the chunks the slice resolves to, so
        # the figure is what the query costs whether the bytes come off a mmap or a wire.
        if p.backend === :indexed
            for (pos, _, _, _) in SlateTask.table_chunks(p.index, local_rows)
                opened += 1; bytes += Int(p.index["chunks"][pos]["bytes"])
            end
        end
        push!(blocks, (length(local_rows), p,
                       part_rows(p, local_rows; select = want === nothing ? nothing : String.(vwant))))
    end
    # `scan` calls this per block and keeps its own totals, so it would otherwise charge a sweep
    # one accounting entry per chunk.
    record && _record!(ds.label, isempty(ds.parts) ? "" : ds.parts[1].root, :rows, bytes, opened,
                       (time() - t0) * 1000)

    lens = Int[b[1] for b in blocks]
    names = Symbol[]; out = Any[]
    # Parameters and facts are constant within a unit, so they are stored once per unit — a few
    # hundred units returning thousands of rows each would otherwise pay millions of copies of a
    # number that took a few hundred values. See `BlockColumn`.
    for k in pwant
        push!(names, k)
        push!(out, _blockcol(Any[b[2].params isa NamedTuple && hasproperty(b[2].params, k) ?
                                 getproperty(b[2].params, k) : missing for b in blocks], lens))
    end
    # The values genuinely differ per row. A unit that produced none is `missing` across its block.
    for c in vwant
        push!(names, _value_name(ds, c))
        push!(out, _narrow(reduce(vcat, Any[haskey(b[3], c) ? collect(b[3][c]) :
                                            fill(missing, b[1]) for b in blocks]; init = Any[])))
    end
    for k in fwant
        push!(names, k)
        push!(out, _blockcol(Any[getproperty(b[2].facts, k) for b in blocks], lens))
    end
    return NamedTuple{Tuple(names)}(Tuple(out))
end
Base.getindex(ds::Dataset, rows::AbstractUnitRange, col::Symbol) = getindex(ds, rows, (col,))[col]

"Part `k` of an array dataset — a handle, not its contents."
function Base.getindex(ds::Dataset, k::Integer)
    ds.kind === :array ||
        error("this dataset is a $(ds.kind) — " *
              (ds.kind === :group ? "`ds[:name]` picks a variable, then `[k]` picks a part" :
               "`ds[rows]` reads rows; `ds.parts[$k]` is the raw part"))
    return ds.parts[k]
end

"""
    keys(ds) -> Vector{String}

The variable names in a group dataset — what an adopted file held. Read off the index, so it costs
nothing. Empty for a table or array dataset, which have one shape and so no names to choose between.
"""
Base.keys(ds::Dataset) =
    ds.kind === :group && !isempty(ds.parts) ?
    String[String(v["name"]) for v in get(ds.parts[1].index, "vars", Any[])] : String[]

"""
    ds[:sst] -> Dataset

One variable of a group dataset, as an ordinary dataset. The whole point of the group being a
namespace rather than a shape: what comes back is a normal `:array` or `:table`, so slicing,
`scan`, chunk pruning and the transfer accounting are the same code they always were.

The variable must be present in every landed unit — a sweep whose units wrote different variables
is several datasets, not one, and is better adopted separately.
"""
function Base.getindex(ds::Dataset, var::Symbol)
    ds.kind === :group ||
        error("this dataset has one shape and no named variables — " *
              (ds.kind === :array ? "`ds[k]` for part k" : "`ds[rows]` for rows"))
    name = String(var)
    parts = DatasetPart[]
    for p in ds.parts
        v = _group_var(p.index, name)
        v === nothing && continue
        idx = Dict{String,Any}(String(k) => vv for (k, vv) in v["index"])
        push!(parts, DatasetPart(p.root, :indexed, idx, p.params, p.facts,
                                 Int(get(idx, "rows", 0)), Int(get(idx, "bytes", 0)),
                                 p.label, p.src))
    end
    isempty(parts) && error("no variable `$(name)` here — this dataset holds " *
                            (isempty(keys(ds)) ? "none" : join(keys(ds), ", ")))
    length(parts) == length(ds.parts) ||
        error("`$(name)` is in $(length(parts)) of $(length(ds.parts)) units — a variable that " *
              "only some units wrote cannot be one dataset")
    return Dataset(_ds_kind(parts[1].index), parts, ds.whole, ds.label, ds.purged; limit = ds.limit)
end

"""
    attributes(ds) -> Dict
    attributes(ds, :sst) -> Dict

What the adopted file said about itself: units, a calendar, a run id — whatever the format carried.
Metadata is most of why a file format was chosen, so it is kept rather than dropped on the way in.
"""
attributes(ds::Dataset) =
    isempty(ds.parts) ? Dict{String,Any}() :
    Dict{String,Any}(get(ds.parts[1].index, "attrs", Dict{String,Any}()))
function attributes(ds::Dataset, var::Symbol)
    isempty(ds.parts) && return Dict{String,Any}()
    v = _group_var(ds.parts[1].index, String(var))
    v === nothing && error("no variable `$(var)` here — this dataset holds " * join(keys(ds), ", "))
    return Dict{String,Any}(get(v, "attrs", Dict{String,Any}()))
end

"The dimension names of one variable, in the order the file stored them (empty when it named none)."
function dimensions(ds::Dataset, var::Symbol)
    isempty(ds.parts) && return String[]
    v = _group_var(ds.parts[1].index, String(var))
    v === nothing && error("no variable `$(var)` here — this dataset holds " * join(keys(ds), ", "))
    return String[String(d) for d in get(v, "dims", String[])]
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
            T = SlateTask.eltype_of(String(p.index["eltype"]))
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
        # Only stored parts have anything to open: inline rows came with the manifest, and a hole
        # has nothing behind it.
        p.backend === :indexed || continue
        cs = get(p.index, "chunks", Any[])
        isempty(cs) && continue
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
# The row ranges a scan walks, and what opening each one costs: one per chunk for an indexed part,
# pruned by `between` wherever the index can answer it, and one whole block for any other part.
function _scan_blocks(ds::Dataset, between)
    out = Tuple{UnitRange{Int},Int,Int}[]
    for (i, p) in enumerate(ds.parts)
        base = ds.starts[i]
        if p.backend !== :indexed || !haskey(p.index, "chunks")
            p.rows > 0 && push!(out, (base:(base + p.rows - 1), 0, 0))
            continue
        end
        keepset = between === nothing ? nothing :
                  Set(SlateTask.prune_chunks(p.index, String(between[1]),
                                             Float64(between[2]), Float64(between[3])))
        at = 0
        for (pos, c) in enumerate(p.index["chunks"])
            nrows = Int(c["rows"])
            (keepset === nothing || pos in keepset) &&
                push!(out, ((base + at):(base + at + nrows - 1), Int(c["bytes"]), 1))
            at += nrows
        end
    end
    return out
end

function scan(ds::Dataset; select = nothing, between = nothing, where = nothing,
              limit::Integer = 10_000)
    ds.kind === :table || error("scan works on table datasets")
    # The names a row comes back under, which is what `load` produces — so a value column colliding
    # with a parameter is `x_result` here too, rather than `x` twice.
    want = if select === nothing
        ns = copy(ds.pnames)
        for c in ds.columns; push!(ns, _value_name(ds, c)); end
        ns
    else
        Symbol[Symbol(s) for s in select]
    end
    # A `where` needs every column it might look at, so a projection is only safe alongside one
    # when the caller has said which columns matter. A `between` needs its own column either way.
    readcols = (select === nothing || where !== nothing) ? nothing :
               unique(Symbol[want; between === nothing ? Symbol[] : Symbol[Symbol(between[1])]])
    keep = [Any[] for _ in want]
    got = 0
    bytes = 0; opened = 0; t0 = time()
    for (rng, b, o) in _scan_blocks(ds, between)
        bytes += b; opened += o
        blk = load(ds, rng; select = readcols, record = false)
        isempty(blk) && continue
        syms = keys(blk)
        for r in 1:length(rng)
            row = NamedTuple{syms}(Tuple(blk[s][r] for s in syms))
            # A hole is a row whose values are all `missing`, so both predicates have to survive one:
            # comparing against `missing` gives `missing`, which is neither a match nor a boolean.
            between === nothing || let v = row[Symbol(between[1])]
                (v !== missing && v >= between[2] && v <= between[3]) || continue
            end
            where === nothing || Base.invokelatest(where, row) === true || continue
            for (j, nm) in enumerate(want); push!(keep[j], row[nm]); end
            got += 1
            got >= limit && @goto done
        end
    end
    @label done
    _record!(ds.label, isempty(ds.parts) ? "" : ds.parts[1].root, :rows, bytes, opened,
             (time() - t0) * 1000)
    return NamedTuple{Tuple(want)}(Tuple(isempty(k) ? k : identity.(k) for k in keep))
end

# ── Handing the dataset to someone else's code ────────────────────────────────────────────────
# A Dataset reads lazily already — a slice opens only the chunks it names, `between` prunes off the
# index, an array part slices by byte offset. What it could not do was let ANOTHER package read it
# that way: a consumer had to be handed materialised columns, which for a dataset that outgrew
# memory meant it could not be handed over at all.
#
# One partition per stored CHUNK is the shape that fixes it, because that is the unit the store is
# already built in. `Arrow.write` and `CSV.write` ask a source for its partitions and write each as
# it arrives, so the peak resident cost is one chunk however large the dataset is.
#
# Deliberately NOT a `Tables.columns` method (see `ext/KaimonSlateTablesExt.jl`): that would mean
# "materialise all of it", which is the one thing `DATASET_ROW_CAP` exists to prevent. Ask for a
# slice when you want that, and the cost stays visible at the call site.

"""
    DatasetPartitions

A Dataset as a sequence of column tables, one per stored chunk. Iterating reads a chunk at a time.
"""
struct DatasetPartitions
    ds::Dataset
    blocks::Vector{Tuple{UnitRange{Int},Int,Int}}
end

"""
    partitions(ds) -> iterator of column tables

The dataset chunk by chunk, in row order, each piece a NamedTuple of columns carrying the
parameters that produced it. This is what lets a dataset larger than memory be written out or read
by another package: only one chunk is resident at a time.

    Arrow.write("out.arrow", ds)        # via Tables.partitions — streams
    for part in Sweep.partitions(ds)    # …or walk it yourself
        @show length(first(part))
    end

Rows that rode a manifest come back as one partition per unit, and a unit that has not landed
contributes its row of `missing` — the same row space `ds[1:n]` has, split along how it is stored.
"""
function partitions(ds::Dataset)
    ds.kind === :table ||
        error(ds.kind === :group ?
              "this dataset holds named variables, not one row space — `ds[:name]` picks one " *
              "(`keys(ds)` lists them), and that is what streams" :
              "this dataset holds arrays, not rows — `ds[k]` for part k, then slice that part")
    return DatasetPartitions(ds, _scan_blocks(ds, nothing))
end

"""
    column_schema(ds) -> (names, types)

What `ds[rows]` will hand back, worked out from the index without reading anything.

`Union{Missing,T}` is decided rather than guessed: a column is missing exactly where a part does not
carry it — a unit that has not landed, or one whose body took a branch that returned different
fields — and which columns a part has is recorded. Parameters are read off the values themselves, so
they need no resolution at all.

A stored column's type is recorded as a NAME, and resolving it needs the package that defines it
loaded here (`SlateTask.eltype_of`). When it will not resolve the answer is `Any`, which is true but
imprecise — better than refusing to answer, and better than a type that cannot be loaded.
"""
function column_schema(ds::Dataset)
    names = Symbol[]; types = Any[]
    for k in ds.pnames
        push!(names, k)
        T = Union{}
        gap = false
        for p in ds.parts
            if p.params isa NamedTuple && hasproperty(p.params, k)
                T = Union{T,typeof(getproperty(p.params, k))}
            else
                gap = true
            end
        end
        T === Union{} && (T = Any)
        push!(types, gap ? Union{Missing,T} : T)
    end
    for (j, c) in enumerate(ds.columns)
        push!(names, _value_name(ds, c))
        # The first part that declares this column names its type; a part that does not declare it
        # is where `missing` comes from.
        T = Any
        gap = false
        for p in ds.parts
            pc = get(p.index, "columns", String[])
            at = findfirst(==(c), String.(pc))
            if at === nothing
                gap = true
            elseif T === Any
                nm = get(p.index, "types", String[])
                at <= length(nm) && (T = try; SlateTask.eltype_of(String(nm[at])); catch; Any; end)
            end
        end
        push!(types, gap ? Union{Missing,T} : T)
        j == length(ds.columns) && break
    end
    return (names, types)
end

"""
    ds[:] -> NamedTuple of columns

Every row. The explicit spelling of "all of it", so the cost is stated where it is paid; the read
guard applies exactly as it does to any other slice.
"""
Base.getindex(ds::Dataset, ::Colon) = load(ds, 1:length(ds))

# ── Tables.jl, for a module that was INCLUDED rather than loaded ──────────────────────────────
# `ext/KaimonSlateTablesExt.jl` covers Slate loaded as a PACKAGE. A notebook is not that case: the
# worker builds `Main.SlateWorker` by including this source (worker.jl: "This is NOT part of `using
# KaimonSlate`"), and Julia fires a package extension only for a package.
#
# So the methods are defined HERE, at module-load time — during worker boot, before any user frame
# exists. That timing is the whole point: defining them later, when a cell first needs them, puts
# them in a NEWER WORLD than the frame that triggered it, so the very cell that caused the
# registration cannot see them and `DataFrame(pilot.dataset)` fails once and works on a re-run.
#
# Resolved by UUID rather than `using`, for the reason `_ds_arrow` gives: `using` reaches only a
# project's DIRECT dependencies, while the manifest is the honest test of "is it available here?".
# It succeeds precisely in the notebooks that could use it — one that wants `DataFrame(ds)` has
# DataFrames, so it has Tables — and does nothing in the rest.
#
# Columns, not rows. A row consumer wants every column in order, which forfeits both projection and
# chunk pruning and pays a NamedTuple per row; `Tables.columns` hands over the vectors `load`
# already built. `DataFrame(ds)` is therefore exactly `DataFrame(ds[:])`.
#
# Skipped while PRECOMPILING, which is the package case and the extension's job. Both would
# otherwise define the same methods on the same `Dataset` — the two are only distinct types when
# this file is included into a worker — and a method the extension overwrites is an error rather
# than a warning: "Method overwriting is not permitted during Module precompilation", which takes
# the whole extension down with it.
let T = (ccall(:jl_generating_output, Cint, ()) == 1) ? nothing :
        try
            Base.require(Base.PkgId(Base.UUID("bd369af6-aec1-5ad0-b16a-f7cc5008161c"), "Tables"))
        catch
            nothing
        end
    if T !== nothing
        @eval begin
            $T.istable(::Type{<:Dataset}) = true
            $T.columnaccess(::Type{<:Dataset}) = true
            $T.columns(ds::Dataset) = ds[:]
            $T.partitions(ds::Dataset) = partitions(ds)
            function $T.schema(ds::Dataset)
                ds.kind === :table || return nothing
                nm, ty = column_schema(ds)
                return $T.Schema(Tuple(nm), Tuple(ty))
            end
        end
    end
end

Base.length(p::DatasetPartitions) = length(p.blocks)
Base.eltype(::Type{DatasetPartitions}) = NamedTuple
Base.IteratorSize(::Type{DatasetPartitions}) = Base.HasLength()
function Base.iterate(p::DatasetPartitions, i::Int = 1)
    i > length(p.blocks) && return nothing
    rng, _, _ = p.blocks[i]
    # Read through `load`, so a partition is the same columns, the same names and the same transfer
    # accounting a slice of that range would give. Recorded per chunk rather than in one lump: a
    # stream can run for a long time, and the read figure should move while it does.
    return (load(p.ds, rng), i + 1)
end

_bytes(n::Integer) = n < 1024 ? "$(n) B" :
                     n < 1024^2 ? "$(round(n / 1024; digits = 1)) KB" :
                     n < 1024^3 ? "$(round(n / 1024^2; digits = 1)) MB" :
                     "$(round(n / 1024^3; digits = 2)) GB"

# A grouped value comes back as a NamedTuple, so it reads the way it was written: a unit that
# reported `(; loss, acc)` is asked for `row.record.loss`.
# `order` is the author's own field order when the manifest recorded one. Without it the fields come
# back however the Dict hashed them, which is stable within a process and nothing more — so a
# results table's columns moved between reads. Sorted otherwise, because arbitrary-but-fixed still
# beats arbitrary.
function _named(s, order = nothing)
    s isa AbstractDict || return s
    ks = order isa AbstractVector ? String[String(k) for k in order if haskey(s, String(k))] :
         sort!(String[String(k) for k in keys(s)])
    for k in sort!(String[String(k) for k in keys(s)])
        k in ks || push!(ks, k)          # anything the recorded order did not name still appears
    end
    return NamedTuple{Tuple(Symbol.(ks))}(Tuple(s[k] for k in ks))
end

# The unit's own return value, as recorded inline in its manifest. Present whenever the value was
# small enough to carry; `nothing` for a unit whose result only exists as bytes.
_record_of(m) = _named(get(m, "value", nothing), get(m, "value_keys", nothing))

# The figure the progress chart plots. `summary =` when the author asked for one — which is how a
# unit whose result is too large to record inline still reports a number — and otherwise the
# recorded value itself, so a sweep that returns a couple of numbers charts without being told to.
_summary_of(m) = _named(get(m, "summary", get(m, "value", nothing)))

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
#
# A unit's result appears in two forms, and the difference is the whole economy of this fabric:
#
#   record   what it RETURNED, inline — present whenever the value was small enough to carry.
#            Free to read across every unit, so this is what a results table is built from.
#   value    a HANDLE on the stored bytes. `row.value[]` fetches; reaching for it across a whole
#            sweep is what the record exists to make unnecessary.
#
# `summary` is the figure the chart plots: `summary =` when the author asked for one, else the
# record. It is additive — asking for a chart never narrows what the record holds.
#
# A row that FAILED carries its message and traceback in `value` — the same slot, because a unit
# produced one thing or the other and `status` already says which. There is deliberately no second
# `error` field to check: a reader that forgot it would silently treat a failure as an empty result.
function _rows(root, params, keys, run, src = LocalSource(root))
    rows = NamedTuple[]
    have = store_rows(root)
    for (prm, k) in zip(params, keys)
        m = get(have, k, nothing)
        if m === nothing
            push!(rows, (; params = prm, status = "", value = nothing, record = nothing,
                           summary = nothing,
                           artifacts = ArtifactRef[], ran_on = "", ms = 0.0, at = 0, bytes = 0,
                           stamp = ""))
            continue
        end
        st = String(get(m, "status", ""))
        val = st == "ok" ? _ref(root, m, src) : get(m, "error", nothing)
        push!(rows, (; params = prm, status = st, value = val,
                       record = _record_of(m),
                       summary = _summary_of(m),
                       artifacts = _arts(root, m, src),
                       ran_on = String(get(m, "ran_on", "")),
                       ms = Float64(get(m, "ms", 0.0)),
                       # WHEN this unit finished — the manifest is written the moment it does.
                       # `ms` said how long it took and nothing said when, so a sweep could not
                       # answer "is this yesterday's result?" without opening the store by hand.
                       at = Int(get(m, "created", 0)),
                       bytes = st == "ok" ? Int(get(get(m, "shape", Dict()), "bytes", 0)) : 0,
                       # What this unit holds, for `landed_digest` — free while the manifest is open.
                       stamp = _unit_stamp(m)))
    end
    return rows
end

# ── Columns ──────────────────────────────────────────────────────────────────────────────────

# `Any[…]` → the narrowest element type that holds it, so a column of numbers is a numeric column
# and a plot or a `sum` over it behaves.
_narrow(col) = identity.(col)

"""
    BlockColumn

A column that is CONSTANT within each unit's block of rows, stored once per block rather than once
per row.

The parameters and the unit's facts are exactly that shape: `ratio` changes once per unit and then
holds for every row that unit produced. Materialising them would store one copy per OUTPUT row, so a
few hundred units returning thousands of rows each would pay millions of copies of a number that
took a few hundred values. Reads like an ordinary vector; `collect` gives the flat one if something
downstream insists.
"""
struct BlockColumn{T} <: AbstractVector{T}
    values::Vector{T}      # one per block
    stops::Vector{Int}     # cumulative last row index of each block
end
Base.size(c::BlockColumn) = (isempty(c.stops) ? 0 : @inbounds(c.stops[end]),)
Base.IndexStyle(::Type{<:BlockColumn}) = IndexLinear()
function Base.getindex(c::BlockColumn, i::Int)
    @boundscheck checkbounds(c, i)
    return @inbounds c.values[searchsortedfirst(c.stops, i)]
end

# One value per block + the block lengths → the column. Narrowed, so a column of numbers is numeric.
function _blockcol(vals::AbstractVector, lens::AbstractVector{Int})
    v = identity.(vals)
    stops = Int[]; at = 0
    for n in lens; at += n; push!(stops, at); end
    return BlockColumn{eltype(v)}(collect(v), stops)
end

# What one unit's stored result IS, as a short string: the content hashes of whatever it wrote,
# whichever form it took. Taken while the manifest is already open, so a sweep's identity costs no
# reads of its own. Blobs are content-addressed, so naming them names the bytes.
function _unit_stamp(m)
    io = IOBuffer()
    print(io, String(get(m, "status", "")), "|")
    d = get(m, "dataset", nothing)
    if d isa AbstractDict
        for c in get(d, "chunks", Any[])
            c isa AbstractDict && print(io, get(c, "blob", ""), ",")
        end
        print(io, "|", get(d, "rows", 0), "|", get(d, "bytes", 0))
    end
    for b in get(m, "bindings", Any[]); b isa AbstractDict && print(io, get(b, "blob", ""), ","); end
    for a in get(m, "artifacts", Any[]); a isa AbstractDict && print(io, get(a, "blob", ""), ","); end
    print(io, "|", first(String(get(m, "error", "")), 120))
    return String(take!(io))
end

"""
    landed_digest(rows) -> String

The identity of WHAT HAS LANDED. A sweep's value is not a function of its source — the same cell
returns nothing on the run that submits and every unit an hour later — so anything downstream needs
a handle on the results themselves before it can decide whether a cached answer still applies.

Built from ROWS the caller already has, never by re-reading the store. A sweep of a few thousand
units is a few thousand manifests, and every caller here has just parsed them for its own purposes;
parsing them again to compute this would double what running a sweep cell costs.

Content, not counts. A retry that turns one failure into a success moves it, and so does one that
replaces a result with different bytes at the same tally — which counting could not see.
"""
landed_digest(rows) = first(_hex(join((r.stamp for r in rows), "\n")), 16)
landed_digest(r::ShardedResult) = landed_digest(getfield(r, :rows))

"""
    refresh!(r) -> r

Re-read the store and the scheduler. This only looks: a started sweep with work left needs
`reconcile_and_sync!` to send the next jobs out, which is what the card's poll does before calling
this. A loop that only refreshes will watch a started sweep sit at zero.
"""
function refresh!(r::ShardedResult)
    # Re-read the STORE, which for a cluster means catching the mirror up first — everything below
    # reads a local path, and without this it would faithfully re-report what the hub already knew.
    sync_in!(r.target)
    root = store_root(r.target)
    l = launcher_for(r.target)
    r.plan = BatchSweep.plan(root, r.run; launcher = l)
    r.rows = _rows(root, r.params, r.keys, r.run, source_of(r.target))
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
    st = BatchSweep.fold(root).status          # status alone: no record is read to find a failure
    failed = [k for k in r.keys if get(st, k, "") == "error"]
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

"""
The channel the card's buttons call. Separate from status so that submitting, cancelling and
resetting are named apart from watching — a status poll still RECONCILES (`status_payload`), so
"separate" is about which calls are deliberate, not about one of them being read-only.
"""
action_channel(run::AbstractString) = "sweep:" * String(run) * ":do"

# ── What the job itself said ─────────────────────────────────────────────────────────────────
# A unit's own failure is on its manifest, and `r.errors` reads it. But the failures that cost the
# most time leave NO manifest: an out-of-memory kill, a walltime cut, a module that would not load,
# a scheduler refusing the request. The unit never got far enough to record anything, so `r.errors`
# is empty and the sweep reports `:exhausted` — "these outran their resources" — without being able
# to show the sentence that says which resource.
#
# That sentence is in the scheduler's job output, which every launcher can already tail. Nothing
# connected it to a sweep, so the one question a stuck run actually raises had no answer here.

"The submissions covering this run, in a stable order. Read from the store's own job index."
function run_jobs(target::SweepTarget, run::AbstractString)
    root = store_root(target)
    want = Set(BatchSweep.sweep_chunks(root, String(run)))
    return sort!(String[nm for (nm, cs) in BatchSweep.known_submissions(root) if any(in(want), cs)])
end
run_jobs(r::ShardedResult) = run_jobs(getfield(r, :target), getfield(r, :run))

"""
    forget_run!(target, run) -> Int

Release a run from the store — its shard manifests, chunk descriptors, submission records and its
own descriptor. Returns how many manifests went; `MemoStore.gc` reclaims the blobs afterwards, since
they are content-addressed and may be shared.

Refuses a run that is ARMED: it may have jobs queued or running, and dropping the descriptors out
from under them leaves work writing results into a store that no longer expects any. Cancel it
first.
"""
function forget_run!(target::SweepTarget, run::AbstractString)
    root = store_root(target)
    # Started is not the question. What must not happen is dropping the descriptors out from under
    # work that is still queued, and a sweep whose units have all landed has none — refusing those
    # made the feature useless, since every run that ever ran was started.
    gone = _run_event_rels(root, String(run))
    if BatchSweep.is_started(root, String(run))
        p = BatchSweep.plan(root, String(run); launcher = launcher_for(target))
        BatchSweep.is_settled(p) ||
            error("sweep $(run) still has work in flight — $(p.shards_done) of $(p.shards_total) " *
                  "units have landed. Cancel it first, then release it.")
    end
    n = BatchSweep.forget_sweep!(root, String(run))
    _forget_events_there!(target, gone)
    sync_out!(target)
    return n
end
forget_run!(r::ShardedResult) = forget_run!(getfield(r, :target), getfield(r, :run))

# Deleting a run's events in the MIRROR is half the job. A pull merges and never deletes, so the
# store's copies come straight back on the next sync and the run reappears — the same way a
# `.started` marker removed only here used to undo a reset. Removal has to be asked for at the
# store, which is what `forget!` is for.
function _forget_events_there!(t::SweepTarget, rel::Vector{String})
    (t isa ClusterTarget && !isempty(t.host) && !isempty(rel)) || return false
    return forget!(remote_store(t), rel)
end

# The relative paths of a run's events, taken BEFORE they are deleted locally.
_run_event_rels(root::AbstractString, run::AbstractString) =
    String["events/" * basename(f) for f in BatchSweep._run_events(root, String(run))]

# Every run this CELL minted that was never started and has nothing landed, except the one just
# written. Phrased as "every" rather than "the previous one" so it is idempotent and clears a
# backlog that accumulated before the rule existed, not only the run immediately before this.
function _forget_stale_runs(root::AbstractString, keep::AbstractString, cell::AbstractString)
    isempty(cell) && return 0          # a run with no cell behind it is nobody's to collect
    n = 0
    # From the cell's own index, not a scan of the store: a store holds one manifest per UNIT, and
    # this runs on every execution of a sweep cell.
    for sw in BatchSweep.cell_runs(root, cell)
        sw == keep && continue
        try
            BatchSweep.is_started(root, sw) && continue
            # Anything that RAN — even to a failure — has a manifest and is kept.
            p = BatchSweep.plan(root, sw)
            p.shards_done == 0 || continue
            n += BatchSweep.forget_sweep!(root, sw)
        catch
            # A store we cannot read is not one to delete from.
        end
    end
    return n
end

"""
    log_files(r) -> Vector{NamedTuple}
    log_files(target, run)

The output files behind this sweep, newest first: `(; job, path, bytes, modified)`, one per array
element of each submission. Listing is separate from reading, so the interesting file — almost
always the most recent — can be opened without dragging every other one across with it.
"""
log_files(r::ShardedResult) = log_files(getfield(r, :target), getfield(r, :run))
# A log's name carries the scheduler's array index — `<job>.<step>.log` — which is also the
# position of its chunk in the job's index. That is the only link between a FILE and the work that
# wrote it, and it is what lets the listing say where a file ran and how it ended rather than
# offering a column of identical names.
# SLURM names a file `<job>.<jobid>_<index>.out`, PBS and the local launcher `<job>.<index>.<ext>`.
# The array INDEX is what maps to a chunk, so the job id in front of it is optional here.
function _log_step(path::AbstractString)
    m = match(r"\.(?:\d+_)?(\d+)\.(?:log|out|err)$", basename(String(path)))
    return m === nothing ? 0 : parse(Int, m.captures[1])
end

# What the chunk last reported about itself, from the newest event it wrote. One read, and nothing
# from the scheduler.
function _chunk_facts(root::AbstractString, chunk::AbstractString)
    isempty(chunk) && return (; node = "", ran = 0, failed = 0, done = 0, total = 0)
    pr = SlateTask.chunk_progress(root, SlateTask.chunk_events(root, String(chunk)))
    return (; pr.node, pr.ran, pr.failed, pr.done, pr.total)
end

# Just the paths. This is all a membership check needs, and it is what `log_stat` reaches for every
# few seconds while someone reads a growing file — the listing proper also asks the far side for
# each job's pids and for whether it is still running, neither of which says anything about whether
# a path is one of ours.
# Which submission wrote this file. The name is everything before the array index, and it is matched
# against the run's own submissions rather than parsed out, so a stray file in the same directory is
# not mistaken for one of ours.
function _log_job(path::AbstractString, names)
    b = basename(String(path))
    for n in names
        startswith(b, String(n) * ".") && return String(n)
    end
    return ""
end

function log_paths(t::SweepTarget, run::AbstractString)
    l = launcher_for(t)
    root = job_root(t)
    names = run_jobs(t, run)
    return Set(String(e.path) for e in BatchLauncher.log_files(l, root, names))
end

function log_files(t::SweepTarget, run::AbstractString)
    l = launcher_for(t)
    root = job_root(t)
    store = store_root(t)
    subs = BatchSweep.known_submissions(store)
    # Whether each submission is still going, in one poll for the whole run. Without it a chunk
    # whose process DIED looks exactly like one still working: the status file stops part-written,
    # so `done < total` with nothing failed, which is also what progress looks like.
    names = run_jobs(t, run)
    live = try; BatchLauncher.poll(l, root, names); catch; Dict{String,Symbol}(); end
    # Every submission's files in ONE listing. A sweep is reconciled, so it is normally several
    # submissions, and a round trip each is what opening the viewer used to cost on a cluster.
    # Deliberately NOT guarded. The caller turns a failure here into `logerr`, which the viewer
    # shows; swallowing it renders an unreachable cluster as "no job output yet".
    files = BatchLauncher.log_files(l, root, names)
    # These two are guarded, because the listing is worth having without them.
    pids = Dict(nm => (try; BatchLauncher.job_pids(l, root, nm); catch; Int[]; end) for nm in names)
    out = NamedTuple[]
    for e in files
        # `<job>.<step>.<ext>`, which is how a path finds the submission that wrote it now that
        # they are not listed one submission at a time.
        nm = _log_job(e.path, names)
        isempty(nm) && continue
        chunks = get(subs, nm, String[])
        step = _log_step(e.path)
        at(v) = (1 <= step <= length(v)) ? v[step] : nothing
        chunk = something(at(chunks), "")
        f = _chunk_facts(store, chunk)
        push!(out, (; job = nm, e.path, e.bytes, e.modified, step, chunk,
                      pid = something(at(get(pids, nm, Int[])), 0),
                      running = get(live, nm, :unknown) === :running,
                      f.node, f.ran, f.failed, f.done, f.total))
    end
    sort!(out; by = e -> (-e.modified, e.path))
    return out
end

# How much of one file may come back. `tail` bounds the LINES at the source; this bounds the
# characters after it, because one line of a binary blob written into a log is still one line.
const LOG_TAIL_LINES = 500
const LOG_TAIL_CHARS = 200_000

"""
    log_tail(r, path; lines = LOG_TAIL_LINES) -> String

One output file's last lines. `path` must be one `log_files` reported.

That check is the point, not a formality: the path arrives from a browser and ends up inside a
command on a login node. Anything not in the listing is refused rather than quoted and hoped for.
"""
log_tail(r::ShardedResult, path::AbstractString; kw...) =
    log_tail(getfield(r, :target), getfield(r, :run), path; kw...)
# Every entry point that takes a path from the browser passes through here first. The check is the
# security boundary, not a nicety: the path is about to be interpolated into a command on a login
# node, so anything the listing did not name is refused rather than quoted and hoped for.
function _known_log(t::SweepTarget, run::AbstractString, path::AbstractString)
    String(path) in log_paths(t, run) ||
        error("no such log for this sweep: $(path)")
    return String(path)
end

"""
    log_stat(r, path) -> (; bytes, modified)

One log's size and mtime. What a live view polls: re-reading only matters once the file has grown,
and this answers that for the cost of a stat rather than a transfer.
"""
log_stat(r::ShardedResult, path::AbstractString) =
    log_stat(getfield(r, :target), getfield(r, :run), path)
log_stat(t::SweepTarget, run::AbstractString, path::AbstractString) =
    BatchLauncher.log_stat(launcher_for(t), _known_log(t, run, path))

"""
    log_slice(r, path; offset = -65536, nbytes = 65536) -> (; text, from, to, size)

A byte range of one log, trimmed to whole lines. A negative `offset` counts from the END, so the
newest page needs no prior knowledge of the size, and paging backwards is asking for
`[from - nbytes, from)` next.

Byte ranges rather than line numbers throughout: a line number cannot be resolved without counting
from the start of the file, which is what a job's output is too large to permit.
"""
log_slice(r::ShardedResult, path::AbstractString; kw...) =
    log_slice(getfield(r, :target), getfield(r, :run), path; kw...)
log_slice(t::SweepTarget, run::AbstractString, path::AbstractString;
          offset::Integer = -(1 << 16), nbytes::Integer = 1 << 16) =
    BatchLauncher.log_slice(launcher_for(t), _known_log(t, run, path); offset, nbytes)

"""
    log_search(r, path, pattern; ignorecase, regex, limit) -> (; total, hits, capped)

Every line of one log matching `pattern`, as `(; offset, line, text)`. `total` counts the whole file
even when `hits` stops at `limit` — "3 of 412" is the number a reader needs, and a count that
silently meant "3 of the first 1000" would be a lie about the file.

The offsets are what a viewer seeks to, so a match is reachable without reading what precedes it.
"""
log_search(r::ShardedResult, path::AbstractString, pattern::AbstractString; kw...) =
    log_search(getfield(r, :target), getfield(r, :run), path, pattern; kw...)
log_search(t::SweepTarget, run::AbstractString, path::AbstractString, pattern::AbstractString;
           ignorecase::Bool = false, regex::Bool = false, limit::Integer = 1000) =
    BatchLauncher.log_search(launcher_for(t), _known_log(t, run, path), String(pattern);
                             ignorecase, regex, limit)

function log_tail(t::SweepTarget, run::AbstractString, path::AbstractString;
                  lines::Integer = LOG_TAIL_LINES)
    known = log_paths(t, run)
    String(path) in known ||
        error("no such log for this sweep: $(path)")
    txt = BatchLauncher.log_tail(launcher_for(t), String(path); lines = Int(lines))
    return length(txt) > LOG_TAIL_CHARS ?
           "… truncated to the last $(LOG_TAIL_CHARS) characters …\n" *
           String(last(txt, LOG_TAIL_CHARS)) : String(txt)
end

"""
    logs(r::ShardedResult; lines = 200, job = "") -> String

Every job behind this sweep, tailed and concatenated. `log_files` + `log_tail` are the finer form
and what the card uses; this is the one-call version for a terminal.

A deliberate fetch, not a property: for a cluster it is a round trip to the login node, so it
happens when asked and never on the card's poll. `job =` narrows to one submission (`run_jobs(r)`
lists them).

    Sweep.logs(r)
    Sweep.logs(r; lines = 20)
"""
logs(r::ShardedResult; kw...) = logs(getfield(r, :target), getfield(r, :run); kw...)

function logs(t::SweepTarget, run::AbstractString; lines::Integer = 200,
              job::AbstractString = "")
    names = isempty(job) ? run_jobs(t, run) : String[String(job)]
    isempty(names) && return ""
    l = launcher_for(t)
    root = job_root(t)
    io = IOBuffer()
    for nm in names
        txt = try
            BatchLauncher.logs(l, root, nm; lines = Int(lines))
        catch e
            # One unreachable job must not hide the others: a partly-readable answer beats none.
            "… could not read this job's output: " * first(sprint(showerror, e), 160)
        end
        isempty(strip(txt)) && continue
        println(io, "── ", nm, " ──")
        println(io, rstrip(txt))
    end
    return String(take!(io))
end

"""
    handle_action(target, run, params, keys, action; plot = nothing, opts = Dict()) -> payload

Apply a control the card offers, then report the resulting state so the button press and the
refresh are one round trip.

`cancel` and `reset` are destructive in different degrees and are kept apart deliberately: cancel
STOPS a sweep and keeps every finished unit, so resuming costs only what is left; reset throws the
results away.

`arg` names a file for the log actions; `opts` is the whole request the browser sent — a NamedTuple,
the shape every `slate_on` handler receives — so an action needing more than one value does not have
to encode them into a string.
"""
# A number out of a browser request, which may arrive as a number or as a string.
_opt_int(opts, key::Symbol, default::Int) =
    (v = get(opts, key, nothing); v === nothing ? default :
     v isa Integer ? Int(v) : something(tryparse(Int, string(v)), default))

# A window and a hit list, bounded HERE rather than trusted from the caller. The viewer asks for a
# page at a time and stops at two thousand hits, but the numbers arrive over the wire and a log is
# the one thing in the store big enough that believing them costs the hub its memory: the reply is
# built in full before any of it is sent.
const LOG_SLICE_MAX = 1 << 22        # 4 MB per window
const LOG_HITS_MAX = 5000
_opt_span(opts, key::Symbol, default::Int, cap::Int) =
    clamp(_opt_int(opts, key, default), -cap, cap)
function handle_action(target::SweepTarget, run::AbstractString, params, keys,
                       action::AbstractString; plot = nothing, notify = nothing,
                       landed = nothing, arg::AbstractString = "", opts = (;))
    # `sync_in!` brings the store's metadata across, a transfer that grows with the sweep. The three
    # reads below want a FILE on the cluster and nothing out of the store, and `log_stat` is polled
    # every few seconds for as long as someone watches a log grow — so they do not pay for it.
    action in ("log_stat", "log_slice", "log_search") || sync_in!(target)
    root = store_root(target)
    l = launcher_for(target)
    # Not a mutation: the card reporting, once, that the work is over. A sweep finishes minutes or
    # hours after the cell that started it returned, so without this the notebook's own view of the
    # results stays frozen at "nothing has landed yet" until someone re-runs a cell by hand — which
    # is exactly the manual bookkeeping this fabric exists to remove.
    if action == "settled"
        # The result object is a SNAPSHOT: its counters come from the plan stored on it, and only a
        # re-run of the sweep cell rebuilds that — which must not happen, or the sweep resubmits. So
        # a settle left `r.settled` reading false beside a card that said "finished, with failures",
        # and every counter with it. Re-read here, where the card has just established that they
        # changed, rather than on property access, where it would cost a manifest per shard.
        landed === nothing || landed()
        notify === nothing || notify()
        return status_payload(target, run, params, keys; plot, advance = false)
    end
    # Also not a mutation — and deliberately only on request. For a cluster this is a round trip to
    # the login node, so it must never ride the poll: a card left open on a finished sweep would be
    # tailing files over ssh every thirty seconds for the rest of the session.
    #
    # What the viewer asks for is STRUCTURED, not markup. It pages a file by byte range and searches
    # the whole of it, neither of which a panel rendered here could do — the file can be larger than
    # anything worth sending, and a rendered tail is the one part of it the reader already saw.
    if action == "logs"
        # Not a status payload. The viewer wants the listing and the vocabulary to read it with,
        # and building the card's view first means a plan and a manifest per shard before any of
        # that starts — on a cluster, ahead of the round trips the listing itself costs.
        out = Dict{String,Any}()
        try
            out["loglist"] = [Dict{String,Any}("path" => String(f.path),
                                               "name" => basename(String(f.path)),
                                               "job" => String(f.job),
                                               "bytes" => Int(f.bytes),
                                               "modified" => Int(f.modified),
                                               "step" => f.step, "chunk" => f.chunk, "pid" => f.pid,
                                               "running" => f.running,
                                               "node" => f.node, "ran" => f.ran,
                                               "failed" => f.failed, "done" => f.done,
                                               "total" => f.total)
                              for f in log_files(target, run)]
        catch e
            out["loglist"] = Dict{String,Any}[]
            out["logerr"] = first(sprint(showerror, e), 300)
        end
        # What counts as an error or a warning, sent rather than restated in JS — the viewer marks
        # the lines it is showing and the card colours the ones it renders, and the two disagreeing
        # about the same line is the bug this prevents.
        out["logsev"] = Dict{String,Any}("declared" => _LOG_LEVEL_SRC,
                                         "error" => [_LOG_BAD_SRC, _LOG_BAD_COUNT_SRC],
                                         "warn" => [_LOG_WARN_SRC],
                                         # Counting a whole file goes by DECLARED level when the
                                         # file has any; the word lists are for output that has none.
                                         "dwarn" => _LOG_DECL_WARN_SRC,
                                         "derror" => _LOG_DECL_BAD_SRC,
                                         # …and the shape of a record, so it can be shown as one.
                                         "head" => _LOG_HEAD_SRC, "field" => _LOG_FIELD_SRC,
                                         "fcont" => _LOG_FCONT_SRC, "mcont" => _LOG_MCONT_SRC,
                                         "tail" => _LOG_TAIL_SRC)
        return out
    end
    # The three reads, each a bare reply rather than a status payload: a viewer polling a growing
    # file must not drag a manifest scan along behind every tick.
    if action == "log_stat"
        st = log_stat(target, run, arg)
        return Dict{String,Any}("bytes" => st.bytes, "modified" => st.modified)
    end
    if action == "log_slice"
        s = log_slice(target, run, arg; offset = _opt_span(opts, :offset, -(1 << 16), typemax(Int) >> 1),
                                        nbytes = _opt_span(opts, :nbytes, 1 << 16, LOG_SLICE_MAX))
        return Dict{String,Any}("text" => s.text, "from" => s.from, "to" => s.to, "size" => s.size)
    end
    if action == "log_search"
        r = log_search(target, run, arg, String(get(opts, :pattern, ""));
                       ignorecase = get(opts, :ignorecase, false) == true,
                       regex = get(opts, :regex, false) == true,
                       limit = clamp(_opt_int(opts, :limit, 1000), 0, LOG_HITS_MAX))
        return Dict{String,Any}("total" => r.total, "capped" => r.capped,
                                "hits" => [Dict{String,Any}("offset" => h.offset, "line" => h.line,
                                                            "text" => h.text) for h in r.hits])
    end
    _with_store_lock(target) do
    if action == "submit"
        BatchSweep.start!(root, run)
    elseif action == "cancel"
        BatchSweep.cancel!(root, run, l)
        BatchSweep.stop!(root, run)
    elseif action == "resume"
        BatchSweep.resume!(root, run)
        BatchSweep.start!(root, run)
    elseif action == "retry"
        # Same reason as reset: dropping a failed unit's manifest only in the mirror leaves it on
        # the cluster, and the next sync brings the failure straight back.
        st = BatchSweep.fold(root).status      # status alone: no record is read to find a failure
        failed = [k for k in keys if get(st, k, "") == "error"]
        forget_results!(target, failed)
    elseif action == "reset"
        # Kill anything live FIRST. `clear_attempts!` forgets the submission records, and with them
        # the job names needed to reach the scheduler — reversing these two would leave orphaned jobs
        # writing results into a store that had just been emptied.
        BatchSweep.cancel!(root, run, l)
        BatchSweep.clear_attempts!(root, run)
        forget_results!(target, keys)
        # Cleared and READY, not stopped: drop the cancellation `cancel!` just wrote, and leave the
        # sweep stopped so submitting it again is a separate decision.
        BatchSweep.resume!(root, run)
        BatchSweep.stop!(root, run)
    else
        error("unknown sweep action: $(action)")
    end
    # Arming, cancellation and cleared attempts are all markers under `jobs/`, so send only that —
    # the same narrowing `reconcile_and_sync!` uses. Sending everything also tars the blob tree,
    # which is large and is being written while it is read.
    #
    # And the result is CHECKED. `jobs/` is deleted on the way out and never on the way in, so a
    # push that did not happen leaves the store holding markers this hub just removed — and the next
    # poll pulls them back. Disarming would silently undo itself and the sweep would resubmit, which
    # reads as the reset button starting a run. Failing here says so instead.
    if !sync_out!(target; dirs = ("jobs",))
        error("sweep $(action): the store was not updated (host unreachable?) — " *
              "the cluster still holds this sweep's markers, so retry once it is reachable")
    end
    end     # _with_store_lock
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
    started = BatchSweep.is_started(root, run)
    p = advance ? reconcile_and_sync!(target, run, l; submit = started && _reachable(target),
                                      failure_policy = sweep_policy(target)) :
                  BatchSweep.plan(root, run; launcher = l)
    t = BatchSweep.telemetry(root, run; launcher = l, plan = p)
    _ds = display_state(p, started)
    _w = _when_stamp(root, run, started)
    # Tile COLOURS, not per-unit statuses: the browser patches tiles by index, and computing the
    # colour here is what keeps the live grid identical to the one the cell rendered. It also keeps
    # the payload flat — a few hundred short strings whatever the sweep's size.
    # `plan` already read every one of these. At a few thousand units a second pass over the store
    # was the bulk of a poll, and the poll has a deadline.
    st = length(p.unit_status) == length(keys) ? p.unit_status :
         (landed = BatchSweep.fold(root).status; [get(landed, k, "") for k in keys])
    rings = _tile_rings(p, BatchSweep.sweep_chunks(root, run), length(st))
    sched = _sched_counts(p)
    tiles = String[]
    for (ti, (lo, hi)) in enumerate(_tile_spans(length(st)))
        ok = count(==("ok"), @view st[lo:hi])
        err = count(==("error"), @view st[lo:hi])
        push!(tiles, _tile_color(ok, err, hi - lo + 1, ti <= length(rings) ? rings[ti] : '.'))
    end

    out = Dict{String,Any}(
        "state" => String(_ds), "label" => _state_label(_ds),
        "total" => p.shards_total, "done" => p.shards_done,
        "ok" => p.shards_ok, "failed" => p.shards_failed, "missing" => p.shards_missing,
        "frac" => BatchSweep.fraction(p),
        "rate" => t.rate_per_s, "eta" => t.eta_s, "idle" => t.idle_s,
        "stuck" => BatchSweep.stalled_for(t), "blocked" => p.blocked,
        "settled" => BatchSweep.is_settled(p), "tiles" => tiles, "rings" => rings,
        "queued" => sched.queued, "running_jobs" => sched.running,
        "color" => get(_STATE_COLOR, _ds, "var(--dim,#6a7090)"),
        # The controls that apply RIGHT NOW, so the card's buttons track its state instead of
        # freezing at whatever was true when the cell last ran.
        "actions" => [Any[a, l] for (a, l) in
                      action_list(p, started; jobs = !isempty(run_jobs(target, run)))],
        # Why it stopped. Carried on every poll because a sweep that blocks WHILE being watched
        # must explain itself then, not only if someone happens to re-run the cell afterwards.
        "why" => _signin_html(target) * _why_html(p),
        # The cluster's host and whether there is a session to it. Without a sign-in the card can
        # read nothing and submit nothing, and that is worth saying on the card rather than leaving
        # it to be discovered as a provisioning failure on the next Submit.
        "host" => target_host(target),
        "when" => _w.at, "when_kind" => _w.kind,
        "signed_in" => connected(target_host(target)))
    # The data line grows as units land, so it rides the poll too. Off the indices, so a sweep
    # writing terabytes still costs manifest reads to watch.
    #
    # Fenced off for the same reason as on the card: this is the one part of the payload that reads
    # the STORE, and a poll that throws stops the counters, the chart and the buttons updating. The
    # data line going quiet is the smaller loss by far.
    try
        ds = _dataset_of(root, params, keys, run, source_of(target))
        out["data"] = _data_html(ds)
        # …and the same two figures as NUMBERS, for the notebook-level pill. The card can render
        # HTML; the topbar panel aggregates across sweeps and needs to add them up.
        if any(p -> p.backend === :indexed, ds.parts)
            out["dsbytes"] = databytes(ds)
            out["dsread"] = transferred(run)
            out["dskind"] = String(ds.kind)
        end
    catch e
        @debug "sweep: could not build the data line" run exception = e
        out["data"] = ""
    end

    # The chart rides the SAME poll as the counters, so a filling plot costs no extra round trip and
    # cannot disagree with the numbers beside it.
    # The failure list rides it too, for the same reason as `why` — and off the same rows the chart
    # already needs, so watching a failing sweep costs no extra manifest reads.
    # These keys are ALWAYS present, even when the answer is "nothing". A payload that can only ADD
    # a chart can never take one away: after a Reset the units are gone, the option is `nothing`, the
    # key was simply omitted — and the card went on showing a chart of results that no longer exist.
    # `nothing` here is an explicit null on the wire, which the card reads as "clear it".
    if plot !== false || p.shards_failed > 0
        rows = _rows(root, params, keys, run, source_of(target))
        opt, err = plot === false ? (nothing, "") : _plot_option(plot, rows)
        out["chart"] = opt
        out["charterr"] = err
        out["fails"] = _fails_html(rows)
    else
        out["chart"] = nothing
        out["charterr"] = ""
        out["fails"] = ""
    end
    return out
end

# ── The chart you get without asking ─────────────────────────────────────────────────────────
# A `paramgrid` is a product of axes, so the shapes a sweep actually produces are few and each has
# one right picture: a number over ONE varying numeric axis is a line; over TWO it is a heatmap.
# Making someone write those out is the ad-hoc wiring this fabric exists to remove.
#
# The earlier rule declined at two axes, reasoning that a line would silently project one of them
# away. True of a line, and the wrong conclusion: the ambiguity was never WHICH axis, it was which
# CHART, and for two numeric axes and one numeric field there is no ambiguity. Declining there meant
# the default gave up on the most common shape a grid can have.
#
# Three or more varying axes still declines, and that one is real: collapsing an axis means choosing
# a reduction (a mean over replications, a slice at one value), and which is the author's claim to
# make. `plot = false` turns it off; `plot = f` replaces it.

# One tile per unit stays flat however large a sweep gets, but a line does not — and neither does
# the payload carrying it. Past this many units the grid IS the right view.
const _AUTO_PLOT_MAX = 2000

# The default heatmap's colour scale: one hue, stepped for a DARK chart surface, so low values
# recede and high ones read brightest. The low end deliberately stops short of the surface rather
# than fading into it — on a heatmap a blank cell means "not run yet", and a lowest-value cell that
# recedes to the background would be indistinguishable from one that has not reported.
# (Validated as a sequential ramp against this surface: monotone lightness, visible step gaps,
# single hue, low end 2.66:1.)
const _AUTO_HEAT_COLORS = ["#1c5cab", "#2a78d6", "#5598e7", "#86b6ef", "#b7d3f6"]

# The grid axes that are numeric AND actually vary, in grid order.
function _auto_axes(rows)
    isempty(rows) && return Symbol[]
    p1 = rows[1].params
    p1 isa NamedTuple || return Symbol[]
    found = Symbol[]
    for k in keys(p1)
        vals = Any[]
        for r in rows
            hasproperty(r.params, k) || return Symbol[]
            push!(vals, getproperty(r.params, k))
        end
        all(v -> v isa Real, vals) || continue
        length(unique(vals)) > 1 && push!(found, k)
    end
    return found
end

# The one numeric field to plot: a bare number is itself; a grouped record plots only when exactly
# ONE of its fields is numeric, because with several, which one is the author's business.
function _auto_field(landed)
    all(r -> r.summary isa Real, landed) && return (true, nothing)
    s1 = landed[1].summary
    s1 isa NamedTuple || return (false, nothing)
    nums = [k for k in keys(s1) if getproperty(s1, k) isa Real]
    length(nums) == 1 || return (false, nothing)
    f = nums[1]
    all(r -> r.summary isa NamedTuple && hasproperty(r.summary, f) &&
             getproperty(r.summary, f) isa Real, landed) || return (false, nothing)
    return (true, f)
end

function _auto_plot(rows)
    (isempty(rows) || length(rows) > _AUTO_PLOT_MAX) && return nothing
    axes = _auto_axes(rows)
    length(axes) in (1, 2) || return nothing
    landed = [r for r in rows if r.status == "ok"]
    isempty(landed) && return nothing
    okf, field = _auto_field(landed)
    okf || return nothing
    zof(r) = r.status != "ok" ? nothing :
             field === nothing ? r.summary : getproperty(r.summary, field)
    length(axes) == 2 && return _auto_heatmap(rows, axes, field, zof)
    ax = axes[1]
    yof = zof
    # `nothing` for a unit that has not reported: the axis is then fixed from the first frame and the
    # line breaks at the real gaps, so the picture only gains detail instead of changing shape.
    return Dict{String,Any}(
        "backgroundColor" => "transparent", "animation" => false,
        # `containLabel` rather than fixed margins: this chart is drawn for values nobody has seen
        # yet, so no hardcoded left inset can be right for both `0.5` and `200,000` — the wide one
        # gets its first digit clipped. Axis NAMES sit in the middle of their axis for the same
        # reason: at the end, a name runs off the edge of the plot area it labels.
        # Same reason as the heatmap below: `containLabel` covers labels, not the axis name.
        "grid"    => Dict("left" => 10, "right" => 18, "top" => 24, "bottom" => 26,
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

# Two varying axes: the grid itself, coloured by the reported figure. Categorical axes over the
# SORTED DISTINCT values of each, so the cells are evenly spaced however the axis is distributed —
# a log-spaced sweep is the normal case and a value axis would crowd every point but the last into
# one corner. A unit that has not reported contributes no cell, so the picture fills in rather than
# changing shape, and the empty squares are where the work still is.
function _auto_heatmap(rows, axes, field, zof)
    xs = sort!(unique(Real[getproperty(r.params, axes[1]) for r in rows]))
    ys = sort!(unique(Real[getproperty(r.params, axes[2]) for r in rows]))
    xi = Dict(v => i - 1 for (i, v) in enumerate(xs))
    yi = Dict(v => i - 1 for (i, v) in enumerate(ys))
    data = Any[]
    lo = Inf; hi = -Inf
    for r in rows
        z = zof(r)
        z === nothing && continue
        push!(data, Any[xi[getproperty(r.params, axes[1])], yi[getproperty(r.params, axes[2])], z])
        lo = min(lo, z); hi = max(hi, z)
    end
    isempty(data) && return nothing
    # One landed unit gives a degenerate scale; widen it so the single cell is drawn rather than
    # falling outside a zero-width range.
    lo == hi && (lo -= 0.5; hi += 0.5)
    return Dict{String,Any}(
        "backgroundColor" => "transparent", "animation" => false,
        # `containLabel` reserves room for axis LABELS and not for axis NAMES, so a `nameGap` that
        # clears the labels then runs off the bottom of the container. The gap below is what the
        # name itself needs, measured from the outside of the labels.
        "grid"    => Dict("left" => 10, "right" => 64, "top" => 24, "bottom" => 26,
                          "containLabel" => true),
        "tooltip" => Dict("position" => "top"),
        "xAxis"   => Dict("type" => "category", "data" => xs, "name" => String(axes[1]),
                          "nameLocation" => "middle", "nameGap" => 26,
                          "splitArea" => Dict("show" => false)),
        "yAxis"   => Dict("type" => "category", "data" => ys, "name" => String(axes[2]),
                          "nameLocation" => "middle", "nameGap" => 52,
                          "splitArea" => Dict("show" => false)),
        "visualMap" => Dict("min" => lo, "max" => hi, "calculable" => true,
                            "orient" => "vertical", "right" => 4, "top" => "middle",
                            "text" => field === nothing ? nothing : [String(field), ""],
                            "textStyle" => Dict("color" => "#6a7090"),
                            "inRange" => Dict("color" => _AUTO_HEAT_COLORS)),
        "series"  => [Dict("type" => "heatmap", "progressive" => 0,
                           "itemStyle" => Dict("borderWidth" => 0), "data" => data)])
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
# WHEN, rather than WHICH. A run is named by a hash of its body, which tells a reader nothing and
# changes silently when they edit the cell — so a card showing a superseded run looked identical to
# one showing theirs. A time answers the question they actually have: is this my current code?
#
# Before submission that is when this version of the body first existed; after it, when someone
# approved spending on it. Both read as past participles so the chip is a sentence about the run
# rather than a label with a number after it. The hub renders a fallback and the browser restates it
# in the reader's own timezone, the way the ETA clock already does.
function _when_stamp(root::AbstractString, run::AbstractString, started::Bool)
    t = started ? BatchSweep.started_at(root, run) : BatchSweep.created_at(root, run)
    return (kind = started ? "submitted" : "written", at = t)
end

# A bare "15:51" is only unambiguous on the day it happened, and a sweep card outlives the day. So
# the day is always said: named while it is recent enough to be worth naming, dated after that.
function _when_text(w)
    w.at <= 0 && return ""
    t = Dates.unix2datetime(w.at) + _localoffset()
    now = Dates.now()
    days = Dates.value(Dates.Date(now) - Dates.Date(t))
    day = days == 0 ? "today" : days == 1 ? "yesterday" :
          Dates.year(t) == Dates.year(now) ? Dates.format(t, "u d") :
          Dates.format(t, "u d yyyy")
    return string(w.kind, " ", day, " ", Dates.format(t, "HH:MM"))
end

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

# What the SCHEDULER is doing with each tile's units, as one character per tile. The fill says how a
# unit ENDED; without this, "nothing yet" covered three unlike situations — not submitted, queued,
# and running on a node — so a sweep waiting on an allocation looked the same as one doing nothing.
#
# Most advanced state wins within a tile: the grid answers "is anything happening here?", and a tile
# spanning a running chunk and a queued one is a place where something is happening.
_ring_tip(c::AbstractChar) =
    c == 'r' ? " · running" : c == 'q' ? " · queued" : c == 'x' ? " · stopped" : ""

const _RING_RANK = Dict(:running => 3, :pending => 2, :blocked => 1, :exhausted => 1)

function _tile_rings(p, chunks, nunits::Integer)
    nunits <= 0 && return ""
    best = zeros(Int, nunits)
    for (i, c) in enumerate(chunks)
        i <= length(p.chunk_spans) || break
        r = get(_RING_RANK, get(p.chunk_state, c, :missing), 0)
        r == 0 && continue
        for u in p.chunk_spans[i]
            u <= nunits && (best[u] = max(best[u], r))
        end
    end
    io = IOBuffer()
    for (lo, hi) in _tile_spans(nunits)
        m = maximum(@view best[lo:hi])
        print(io, m == 3 ? 'r' : m == 2 ? 'q' : m == 1 ? 'x' : '.')
    end
    return String(take!(io))
end

# How many chunks the scheduler is holding, for the line beside the counts. A ring shows the shape;
# a number survives the grid being binned.
_sched_counts(p) = (queued  = count(==(:pending), values(p.chunk_state)),
                    running = count(==(:running), values(p.chunk_state)))

# The one definition of how units map onto tiles. The renderer and the live payload MUST agree: the
# browser patches tiles by index, so if the two binned differently the grid would either stop
# updating or repaint the wrong cells — and only on large sweeps, which are the ones worth watching.
function _tile_spans(n::Integer)
    n <= 0 && return Tuple{Int,Int}[]
    per = max(1, cld(n, _TILE_BUDGET))
    return [((t - 1) * per + 1, min(t * per, n)) for t in 1:cld(n, per)]
end

# A tile with NOTHING landed is where the scheduler's answer belongs. Flat grey said "not
# submitted", "queued" and "running on a node" all the same way, which is the ambiguity that had a
# sweep waiting on an allocation looking like one doing nothing.
#
# Fill rather than a ring: at five pixels a two-pixel border is most of the tile, and a green ring on
# a green fill is a slightly darker dot. Dim and desaturated so finished work stays the loudest thing
# in the grid, and BLUE for running, which green would have read as "ok".
const _PENDING_FILL = Dict('q' => "#6b5a1f", 'r' => "#1f4f73", 'x' => "#5c2b2b")

# Green for completed, blended toward red by the bucket's failure fraction, so a region that is
# merely slow and a region that is failing do not look alike.
function _tile_color(ok::Int, err::Int, total::Int, sched::AbstractChar = '.')
    done = ok + err
    done == 0 && return get(_PENDING_FILL, sched, "#30363d")
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
function _target_line(t::ClusterTarget)
    # The scheduler leads, then where it is. Which scheduler ran the work is worth reading off the
    # card: the resources beside it mean different things on each, and the same notebook can point
    # at either. Matches the cluster summary the cell's ⚙ shows.
    bits = String[isempty(t.host) ? String(t.kind) : string(t.kind, " · ", t.host)]
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
# The resolved number, not `t.procs`: a target that names none still runs at some width, and that is
# the figure that explains how long the run is taking.
_target_line(t::LocalTarget) = "local · $(local_procs(t)) at once · $(t.chunk)/job"

function _unit_grid(io, r::ShardedResult)
    n = length(r.rows)
    n == 0 && return
    spans = _tile_spans(n)
    per = n == 0 ? 1 : max(1, cld(n, _TILE_BUDGET))
    side = length(spans) <= 100 ? 12 : length(spans) <= 400 ? 8 : 5

    # What the scheduler is holding, per tile. Drawn as a ring so it reads independently of the
    # fill, which answers a different question (how the unit ended).
    rings = _tile_rings(r.plan, BatchSweep.sweep_chunks(store_root(r.target), r.run), n)
    print(io, "<div data-sw='grid' style='display:flex;flex-wrap:wrap;gap:2px;margin-top:8px'>")
    for (ti, (lo, hi)) in enumerate(spans)
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
        ring = ti <= length(rings) ? rings[ti] : '.'
        print(io, "<div title=\"", tip, _ring_tip(ring), "\" style='width:", side, "px;height:", side,
                  "px;border-radius:2px;background:", _tile_color(ok, err, hi - lo + 1, ring), "'></div>")
    end
    println(io, "</div>")
    per > 1 && println(io, "<div style='font-size:10px;opacity:.45;margin-top:3px'>",
                           "each tile ≈ ", per, " units</div>")
end

# How much output is sitting out there, and how much of it this session has actually pulled in.
# Only for output that LIVES IN THE STORE: a sweep whose rows ride the manifests has no transfer to
# account for, so there is nothing here to say. Built from the indices, so showing it reads no data.
function _data_html(ds::Dataset)
    stored = count(p -> p.backend === :indexed, ds.parts)
    stored == 0 && return ""
    tot = databytes(ds)
    got = transferred(ds.label)
    x = transfers(; label = ds.label)
    bits = [string(stored, " part", stored == 1 ? "" : "s"),
            ds.kind === :table ? string(length(ds), " rows") : string(length(ds), " elements"),
            _bytes(tot) * " stored"]
    push!(bits, got == 0 ? "nothing read yet" :
                string(_bytes(got), " read",
                       tot > 0 ? " (" * string(round(100 * got / tot; digits = 2)) * "%)" : "",
                       " · ", x.rate))
    return string("<div style='font-size:11px;color:var(--val,#4ec9b0);opacity:.85;margin-top:4px;",
                  "font-family:ui-monospace,monospace'>", _esc(join(bits, " · ")), "</div>")
end

# …and the same, for a dataset that cannot be ASSEMBLED. Building it reconstructs indexes from the
# store, which is the one part of a card that fails for reasons the sweep itself is fine about, so
# the progress the card exists to show has to outlive that.
function _safe_data_html(r::ShardedResult)
    try
        return _data_html(r.dataset)
    catch e
        @debug "sweep: could not build the data line" exception = e
        return ""
    end
end

# Why a sweep stopped, and what to do about it. The three ways of stopping short need different
# things, so they read differently. "" while the sweep is still going.
# A cluster nobody has signed in to. The card can read nothing and submit nothing until then, so it
# says so up front rather than letting it surface as a provisioning failure on the next Submit.
function _signin_html(target::SweepTarget)
    h = target_host(target)
    (isempty(h) || connected(h)) && return ""
    return string("<div style='margin-top:8px;padding:8px;border-radius:6px;",
                  "background:color-mix(in srgb, var(--amber,#d9a441) 12%, transparent);",
                  "font-size:12px;color:var(--amber,#d9a441)'>🔒 ", _esc(h),
                  ": not signed in — use the padlock at the top of the page</div>")
end

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

# ── The job's own output ─────────────────────────────────────────────────────────────────────
# Fetched on request, never on the poll. What a reader wants is almost always the MOST RECENT
# element of the most recent job, so the files are listed newest first and one is opened at a time.

# The lines worth finding at a glance. A job's output is mostly a package loading; what matters is
# the sentence that says it died, and on a killed job that sentence is near the end of thousands of
# uninteresting ones.
# Words that mean it went wrong on their own. `failed` and `cancelled` are deliberately NOT here:
# the runner's own success line reads "4 ran, 0 skipped, 0 failed of 4", and colouring that red
# makes the most common line in a healthy log look like the thing you are hunting for.
#
# Held as SOURCE, because three engines read these: Julia colours the card, JavaScript marks the
# lines on screen, and ripgrep counts them over a whole file. The syntax is the intersection of all
# three — no inline `(?i)`, which JavaScript has no notion of, so the fold is a flag on each side;
# and no look-around, which Rust's engine does not implement at all and silently never matches.
# Two of the three engines see the line with its colour codes still on it. Julia and JavaScript
# strip first; ripgrep scans the file as it is, and there a word boundary is not where it looks.
# `\e[1mWarning` has no boundary before the `W`, because the `m` that ends the escape is a word
# character. So an escape sequence is accepted ANYWHERE a boundary is, in every pattern below.
const _ANSI_SGR_SRC = raw"\x1b\[[0-9;]*m"
const _ANSI_B = "(?:" * _ANSI_SGR_SRC * raw"|\b)"
const _LOG_BAD_SRC = _ANSI_B * raw"(error|fatal|traceback|exception|segmentation fault|killed|oom|out of memory|exceeded|abort(ed)?)\b"
# …so a count of failures is matched by its NUMBER instead, and only a non-zero one.
const _LOG_BAD_COUNT_SRC = _ANSI_B * raw"[1-9][0-9]*\s+(failed|failures?|errors?)\b"
const _LOG_WARN_SRC = _ANSI_B * raw"(warn|warning|deprecat)"
# A line that NAMES its level is believed, and nothing else is consulted. `@info "0 errors so far"`
# contains the word `error` and is not one; the patterns above are for output that declares nothing
# — a bare `println`, a C library, a scheduler's own messages. This is the shape Julia's logger
# writes, which is what the task runner installs and what a sweep body is meant to use.
_log_level_src(lvl::AbstractString) =
    "^(?:" * _ANSI_SGR_SRC * raw"|\s)*[┌\[](?:" * _ANSI_SGR_SRC * raw"|\s)*" * lvl * raw"\b"
const _LOG_LEVEL_SRC = _log_level_src(raw"(Error|Warning|Info|Debug)")
# One level at a time, for COUNTING. The word patterns above are the fallback for output that
# declares nothing, and counting a whole file with them says 122 where a reader sees 2: a body
# logging `@info … deprecated_option=false` matches `deprecat` on every line it writes. The reader
# does not make that mistake, because a line that names its level is believed — but that rule needs
# to look at the rest of the line, and the count runs in ripgrep, which has no look-around. So the
# count asks the question ripgrep CAN answer exactly: how many records declare this level.
const _LOG_DECL_WARN_SRC = _log_level_src("Warning")
const _LOG_DECL_BAD_SRC = _log_level_src("Error")
# The SHAPE of one record, for a reader that wants to show it as a record rather than as five
# lines of box drawing. `Logging.ConsoleLogger` writes
#
#     ┌ Info 18:19:12.865: iterating          ← head: level, the runner's clock, the message
#     │   residual = 0.003521                 ← field, indented two past the `│`
#     │   exception =                         ← …whose value may run on, indented further
#     │    Stacktrace:
#     │ line two of the message               ← a message continuation is NOT indented
#     └ @ Main.SlateShard none:10             ← tail: where it was logged
#
# Served beside the severity vocabulary for the same reason: one definition of what a record is, so
# the viewer and the card cannot come to different conclusions about the same line. Unlike the
# patterns above these never reach ripgrep, so they read the line with its colour already off.
# A stock logger writes no clock and `[ ` for a record with nothing under it; both are accepted.
const _LOG_HEAD_SRC = raw"^[┌\[] (Error|Warning|Info|Debug)(?: ([0-9:.]+))?: ?(.*)$"
const _LOG_FIELD_SRC = raw"^│ {3}([^ =][^=]*?) = ?(.*)$"
const _LOG_FCONT_SRC = raw"^│ {4,}(.*)$"
const _LOG_MCONT_SRC = raw"^│ ([^ ].*)$"
const _LOG_TAIL_SRC = raw"^└ @ (.*)$"

const _LOG_LEVEL = Regex(_LOG_LEVEL_SRC)
const _LOG_BAD = Regex(_LOG_BAD_SRC, "i")
const _LOG_BAD_COUNT = Regex(_LOG_BAD_COUNT_SRC, "i")
const _LOG_WARN = Regex(_LOG_WARN_SRC, "i")

_declared_level(line) = (m = match(_LOG_LEVEL, line); m === nothing ? nothing :
                         m.captures[1] == "Error" ? :bad :
                         m.captures[1] == "Warning" ? :warn : :plain)

# Colour off first, which is also what the viewer does (`slateAnsiText`). The patterns above cope
# with escape codes on their own, because ripgrep has to; here the line is already in hand, and
# stripping is cheaper and exact.
#
# Spelled out here rather than reached for in the parent module: this file is included into a BARE
# module on purpose — that is how the worker builds it — and a parent that happens to carry
# `termcook.jl` is a property of two of its three callers, not of the file. `test_ansi_parity` holds
# this and `strip_ansi` to the same answer.
const _ANSI_ESC = r"\e[\]P^_X][^\a\e]*(?:\a|\e\\)?|\e\[[0-9;:?<>=!]*[\x40-\x7e]|\e[\x40-\x5f]"
_uncolour(line) = occursin('\e', line) ? replace(String(line), _ANSI_ESC => "") : String(line)

function _log_severity(line)
    t = _uncolour(line)
    d = _declared_level(t)
    d === nothing || return d
    return (occursin(_LOG_BAD, t) || occursin(_LOG_BAD_COUNT, t)) ? :bad :
           occursin(_LOG_WARN, t) ? :warn : :plain
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
    started = BatchSweep.is_started(store_root(r.target), r.run)
    _when = _when_stamp(store_root(r.target), r.run, started)
    st = display_state(p, started)
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
              "<span data-sw='when' data-ts='", _when.at, "' data-kind='", _when.kind,
              "' style='opacity:.5;font-size:12px'>", _esc(_when_text(_when)), "</span>",
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
    # What the scheduler is holding. Without it, a sweep whose every job is queued reads as one
    # doing nothing at all, and the only way to tell was to go and ask the cluster.
    _sc = _sched_counts(p)
    print(io, "<span data-sw='sched' style='opacity:.7'>",
              _esc(join(filter(!isempty, [_sc.running > 0 ? "$(_sc.running) running" : "",
                                          _sc.queued > 0 ? "$(_sc.queued) queued" : ""]), " · ")),
              "</span>")
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
    # Everything about STORED OUTPUT is optional chrome on a card whose job is to report progress, so
    # it is fenced off. A `text/html` method that throws does not surface as an error — the notebook
    # falls back to the next MIME and the card silently becomes a line of text — so a dataset the
    # store cannot answer for would take the whole card down and give no clue why.
    print(io, "<div data-sw='data'>", _safe_data_html(r), "</div>")
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
# outstanding that has not been started is READY, not pending: nothing is queued and nothing will be
# until it is submitted.
display_state(p::BatchSweep.Plan, started::Bool) =
    (!started && p.state === :pending) ? :ready : p.state

function action_list(p::BatchSweep.Plan, started::Bool = true; jobs::Bool = false)
    st = display_state(p, started)
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
    # What the JOB said, as opposed to what a unit recorded. Offered exactly when a submission is on
    # record, because that is when an output file exists to read — and it is the ONLY account of a
    # failure that left no manifest, which is the state (`:exhausted`) where the card otherwise has
    # nothing to show but a count.
    jobs && push!(acts, ("logs", "Logs"))
    # Reset is available the moment there is anything to throw away — finished units, submission
    # history, or work in flight. Offering it only once a sweep had settled stranded the case you
    # most want out of: a long run that is half done and going wrong. It is confirmed in the browser
    # rather than rationed here.
    (p.shards_done > 0 || started || p.state in (:cancelled, :blocked, :exhausted)) &&
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
    for (act, label) in action_list(r.plan, BatchSweep.is_started(store_root(r.target), r.run);
                                    jobs = !isempty(run_jobs(r)))
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
             display_state(r.plan, BatchSweep.is_started(store_root(r.target), r.run)) === :ready)
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
                   missing: $(r.plan.shards_missing), host: "$(_esc(target_host(r.target)))",
                   state: "$(display_state(r.plan, BatchSweep.is_started(store_root(r.target), r.run)))" };

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
      // An ABSOLUTE unix time as the reader's wall clock. The DAY is always said: a bare "15:51"
      // is only unambiguous on the day it happened, and a card outlives the day.
      function at(u){
        var t = new Date(u * 1000), now = new Date();
        var hhmm = String(t.getHours()).padStart(2, "0") + ":" + String(t.getMinutes()).padStart(2, "0");
        var d0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        var d1 = new Date(t.getFullYear(), t.getMonth(), t.getDate());
        var days = Math.round((d0 - d1) / 86400000);
        var day = days === 0 ? "today" : days === 1 ? "yesterday"
                : t.toLocaleDateString(undefined, t.getFullYear() === now.getFullYear()
                    ? { month: "short", day: "numeric" }
                    : { year: "numeric", month: "short", day: "numeric" });
        return day + " " + hhmm;
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
      var chartSig = "";
      function sigOf(opt){
        try { return (opt.series || []).map(function(x){ return x.type || ""; }).join(","); }
        catch (e) { return ""; }
      }
      function drawChart(opt){
        var el = root.querySelector('[data-sw="chart"]');
        if (!el || !opt || !window.echarts) return;
        // Reveal BEFORE init. ECharts measures its container, and an instance created inside a
        // `display:none` div has zero size and draws nothing — so a card that rendered with no
        // landed units (hidden, because the automatic plot cannot know its shape until one
        // reports) stayed blank even once a poll had a chart for it, until the cell was re-run.
        if (el.style.display === "none") el.style.display = "";
        if (!chart) {
          chart = window.chartRuntime ? window.chartRuntime.init(el) : window.echarts.init(el);
        }
        // Merge while the SHAPE is unchanged, so a filling sweep animates from the points already
        // drawn. When the series change kind — a line becoming a heatmap once a second axis starts
        // varying — merging would leave both on screen, so that case replaces instead.
        var sig = sigOf(opt);
        try { chart.setOption(opt, { notMerge: sig !== chartSig, lazyUpdate: true }); } catch (e) {}
        chartSig = sig;
      }
      // Nothing left to draw — after a Reset, most obviously. Said with an explicit null rather
      // than an absent key, because a payload that can only ADD a chart can never take one away.
      function clearChart(){
        var el = root.querySelector('[data-sw="chart"]');
        if (chart) { try { chart.clear(); } catch (e) {} }
        if (el) el.style.display = "none";
        chartSig = "";
      }
      function paint(s){
        last = s;
        // Feed the notebook-level pill. The card is inside one cell's output; the pill is what
        // answers "what is this notebook doing" when that cell is scrolled away or collapsed.
        if (window.slateSweeps) {
          var cell = root.closest('[data-cid]');
          // The CHANNEL rides along so the log viewer can read any sweep in the notebook, not
          // only the card it was opened from.
          window.slateSweeps.report("$(id)", cell ? cell.dataset.cid : "", s, "$(doch)");
        }
        if (s.chart) drawChart(s.chart);
        else if (s.chart === null) clearChart();
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
        // What the scheduler is holding right now. The ring shows where; this says how much, which
        // the grid cannot once it is binned.
        set("sched", s.running_jobs > 0 || s.queued > 0
              ? [s.running_jobs > 0 ? s.running_jobs + " running" : "",
                 s.queued > 0 ? s.queued + " queued" : ""].filter(Boolean).join(" · ") : "");
        set("rate", s.rate > 0 && !s.settled ? s.rate.toFixed(2) + "/s" : "");
        // How much longer, and WHEN that is. Computed in the browser so the clock time is the
        // reader's own — a hub in another timezone would otherwise quote a finish time in its.
        set("eta", (s.eta >= 0 && !s.settled && !s.stuck) ? dur(s.eta) + " left · done ~" + clock(s.eta) : "");
        set("label", s.label);
        // WHEN this card's code was written, or when it was submitted. Formatted here so the time
        // is the reader's own, like the ETA clock above.
        var w = root.querySelector('[data-sw="when"]');
        if (w && s.when !== undefined) {
          w.dataset.ts = s.when; w.dataset.kind = s.when_kind || "";
          w.textContent = s.when > 0 ? (s.when_kind + " " + at(s.when)) : "";
        }
        var lab = root.querySelector('[data-sw="label"]');
        if (lab) lab.style.color = s.color;
        var dot = root.querySelector('[data-sw="dot"]');
        if (dot) dot.style.background = s.color;
        var g = root.querySelector('[data-sw="grid"]');
        if (g && s.tiles && g.children.length === s.tiles.length){
          // One channel, the fill: how the units ended once any have, and what the scheduler is
          // holding until then. Julia has already folded the two together.
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
      // Submit is the control that SPENDS: queue time, an allocation, on a shared machine someone
      // else is waiting for. The button says how much before you press it, but a keybinding does not
      // show you a label — so the count and the destination are asked here, where both paths meet.
      function confirmSubmit(){
        var n = last.missing || 0;
        var msg = "Submit " + n + " unit" + (n === 1 ? "" : "s") +
                  (last.host ? " to " + last.host : " locally") + "?";
        return window.confirmDark ? window.confirmDark(msg, "Submit")
                                  : Promise.resolve(window.confirm(msg));
      }
      function runAction(act, btn){
        if (btn.disabled) return;
        // Logs is not a control — it opens a reader. The viewer talks to this card's channel
        // directly, which is also how it switches between the notebook's other sweeps.
        if (act === "logs") {
          if (window.slateLogs) window.slateLogs.open("$(id)", "$(doch)");
          return;
        }
        var was = btn.textContent;
        // Disabled for the confirmation too, not just the call: an impatient second click would
        // otherwise stack a second dialog on the first.
        btn.disabled = true;
        (act === "reset" ? confirmReset() :
         act === "submit" ? confirmSubmit() : Promise.resolve(true)).then(function(ok){
          if (!ok) { btn.disabled = false; return; }
          btn.textContent = "…";
          // Asking this card to start work IS watching it. Without this, a sweep submitted from a
          // card that rendered `ready` never announces its settle: `watching` was seeded false at
          // render (nothing to watch yet) and is otherwise only set when a poll timer starts — which
          // never happens if the work finishes before the submit's own reply lands. A handful of
          // fast units on a nearby cluster do exactly that, and the cells reading the sweep then sit
          // stale until someone re-runs them by hand.
          if (act === "submit" || act === "resume" || act === "retry") watching = true;
          window.slateCall("$(doch)", { action: act }).then(paint).then(function(){
            // `syncActions` restores the label by rebuilding the row, and it rebuilds only when the
            // SET of actions changed. Submit, Cancel and Retry all change it; a read-only action
            // like Logs does not, so its button kept the "…" and stayed disabled for good.
            btn.disabled = false;
            if (btn.textContent === "…") btn.textContent = was;
          }).catch(function(e){
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
    st = display_state(p, BatchSweep.is_started(store_root(r.target), r.run))
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

    # WHEN, which nothing said before. "4/4 succeeded" reads the same for a run that finished a
    # minute ago and one from last month, and those call for different things.
    ats = [row.at for row in getfield(r, :rows) if row.at > 0]
    if !isempty(ats)
        lo, hi = extrema(ats)
        stamp(u) = Dates.format(Dates.unix2datetime(u) + _localoffset(), "yyyy-mm-dd HH:MM:SS")
        age = _dur(max(0.0, time() - hi))
        println(io, "   ", lo == hi ? stamp(hi) : string(stamp(lo), " → ", stamp(hi)),
                "  (", age, " ago)")
    end

    idle = BatchSweep.stalled_for(t)
    idle > 0 && println(io, "   ⚠ nothing has finished in $(_dur(idle)) — it may be stuck.")

    if p.state === :blocked
        println(io, "   🛑 $(p.blocked)")
        println(io, "   Nothing further will be submitted. Fix the body, then `Sweep.reset!(r)`.")
        println(io, "   `Sweep.logs(r)` shows what the job itself printed.")
    elseif p.state === :cancelled
        println(io, "   Stopped at your request. $(p.shards_done) finished units are kept — ",
                    "`Sweep.resume!(r)` continues with the remaining $(p.shards_missing).")
    elseif p.state === :partial
        println(io, "   `r.errors` lists them; `Sweep.retry_failed!(r)` clears them for a retry.")
    elseif p.state === :exhausted
        println(io, "   Attempted $(BatchSweep.MAX_ATTEMPTS)× without landing, so these units are ",
                    "outrunning their resources rather than erroring.")
        # These units left no manifest, so there is no error to read: the kill message exists only
        # in the job's own output. Pointing at it is the difference between a diagnosis and a guess
        # about which resource ran out.
        println(io, "   `Sweep.logs(r)` shows the kill message. Raise the walltime or memory, ",
                    "then `Sweep.reset!(r)`.")
    elseif p.state !== :succeeded
        println(io, "   re-run this cell to refresh.")
    end

    _text_results(io, r)
    return nothing
end

# ── The sweep in words ───────────────────────────────────────────────────────────────────────
# A sweep cell renders as an HTML card, and in a notebook the richer MIME always wins — so the
# `text/plain` form, which is what a terminal, a log, a standalone `julia notebook.jl` run and a
# copy-paste into a message all need, was written and then unreachable.
#
# One renderer, two surfaces: `show(::MIME"text/plain")` and `text(r)` are the same function, so
# there is no second version of the truth to drift.

const _TEXT_ROWS = 12

# The results table, aligned, first rows only. Manifest-only like everything else here.
function _text_results(io, r::ShardedResult)
    # The row space can be enormous and this prints a dozen rows, so the head is bounded at the call
    # rather than materialised and then cut.
    ds = try; r.dataset; catch; nothing; end
    ds === nothing && return nothing
    n = ds.kind === :table ? length(ds) : nparts(ds)
    n == 0 && return nothing
    shown = min(n, _TEXT_ROWS)
    tb = if ds.kind === :table
        try; ds[1:shown, (ds.pnames..., Symbol.(ds.columns)..., :status)]; catch; NamedTuple(); end
    else
        # No row space — each unit is an array or an adopted file. The grid still reads: the
        # parameters beside how that unit went.
        ps = ds.parts[1:shown]
        cs = Any[_narrow(Any[p.params isa NamedTuple && hasproperty(p.params, k) ?
                             getproperty(p.params, k) : missing for p in ps]) for k in ds.pnames]
        push!(cs, String[p.facts.status for p in ps])
        NamedTuple{(ds.pnames..., :status)}(Tuple(cs))
    end
    (isempty(tb) || isempty(first(tb))) && return nothing
    cols = collect(keys(tb))
    # A cell is one value, not a place for a paragraph: a unit can record a short string, and one
    # long one would otherwise set the width of the whole column.
    cell(v) = v === missing ? "—" :
              v isa AbstractFloat ? string(round(v; sigdigits = 5)) :
              (s = string(v); length(s) > 24 ? first(s, 21) * "…" : s)
    body = [[cell(tb[c][i]) for c in cols] for i in 1:shown]
    w = [max(length(String(cols[j])), maximum(length(row[j]) for row in body; init = 0))
         for j in eachindex(cols)]
    println(io)
    println(io, "   ", join((rpad(String(cols[j]), w[j]) for j in eachindex(cols)), "  "))
    for row in body
        println(io, "   ", join((rpad(row[j], w[j]) for j in eachindex(cols)), "  "))
    end
    n > shown && println(io, "   … and ", n - shown, " more rows — `r.dataset[1:", n, "]` for them")
    return nothing
end

"""
    SweepReport

What `text` hands back. Carries the report and nothing else, and prints as itself rather than as a
quoted string — a `String` returned to a cell renders as its repr, which is the whole report on one
line with the newlines escaped, and that is the one thing this form exists to avoid.

Converts and prints as text, so it still goes into a log line or a message: `String(rep)`,
`print(rep)`, `"\$rep"` all give the report.
"""
struct SweepReport
    text::String
end
Base.show(io::IO, ::MIME"text/plain", x::SweepReport) = print(io, x.text)
Base.show(io::IO, x::SweepReport) = print(io, x.text)
Base.print(io::IO, x::SweepReport) = print(io, x.text)
Base.String(x::SweepReport) = x.text
Base.length(x::SweepReport) = length(x.text)

"""
    text(r) -> SweepReport

The sweep as plain text: state, progress, timing, and the first rows of `r.dataset`.

The same rendering `show` produces for a REPL, reachable on demand — in a notebook the HTML card
wins the MIME negotiation, so the text form has no way to the screen on its own.

    Sweep.text(r)          # renders as the report, in a cell or a REPL
    print(Sweep.text(r))   # …and to a terminal, a log, or a message

One renderer behind both, so the card and the text cannot drift.
"""
text(r::ShardedResult) = SweepReport(sprint((io, x) -> show(io, MIME"text/plain"(), x), r))

# The COMPACT form: `@show`, an element of a vector, an interpolation into an error. Julia's default
# for a struct is a dump of every field, and one of this struct's fields is every ROW — so `@show r`
# on a real sweep printed the whole grid, parameters and handles and all, because someone wanted one
# line. `ShardRef` and `Dataset` both define this; the thing holding thousands of them did not.
# Manifests record unix time, which is UTC. A reader wants the clock on their own wall, and the
# hub may not be in the same zone as the cluster that wrote the stamp.
_localoffset() = Dates.Millisecond(round(Int, 1000 * (Dates.datetime2unix(Dates.now()) -
                                                     Dates.datetime2unix(Dates.now(Dates.UTC)))))

"Where a sweep runs, in one word — `local`, or the scheduler and the login node it goes through."
_target_label(::LocalTarget) = "local"
_target_label(t::ClusterTarget) = isempty(t.host) ? String(t.kind) : string(t.kind, "@", t.host)

function Base.show(io::IO, r::ShardedResult)
    p, tel = getfield(r, :plan), getfield(r, :telemetry)
    tgt = getfield(r, :target)
    # `is_started` is one file check, but `show` is called from places that must never throw — an
    # error message, a logging call, a store that has gone away underneath.
    st = try
        display_state(p, BatchSweep.is_started(store_root(tgt), getfield(r, :run)))
    catch
        p.state
    end
    # Everything below is already in the struct — the rows, the plan, the telemetry — so a one-line
    # form costs no reads. What it says is what someone glancing at a binding wants: how far along,
    # how much it is holding, where it ran, and when it will be done if it is not.
    b = sum(row.bytes for row in getfield(r, :rows); init = 0)
    print(io, "ShardedResult(", first(getfield(r, :key), 12), ", ", st, ", ",
          p.shards_done, "/", p.shards_total,
          p.shards_failed > 0 ? " ✗$(p.shards_failed)" : "")
    b > 0 && print(io, ", ", _bytes(b))
    print(io, " on ", _target_label(tgt))
    st === :running && tel.eta_s >= 0 && print(io, ", ~", _dur(tel.eta_s), " left")
    print(io, ")")
end

# ── The sweep itself ─────────────────────────────────────────────────────────────────────────

"""
    run_sweep(target, params, body_src; setup_src = "", captures = Dict(), submit = false) -> ShardedResult

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
                   submit::Bool = false, cap::Integer = 0, register = nothing, probe::Bool = true,
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
    target = with_probe(with_chunk(target, attr_chunk(attrs)), probe ? 1 : 0)
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
    # What the store already holds, decided ONCE here rather than per unit on a compute node. A
    # shard key names a body and a parameter point and no run, so a pilot's results are this
    # sweep's results; the descriptor carries the answer so the node needs no lookup at all.
    landed = Set(k for (k, _) in BatchSweep.fold(root).status)
    for (ci, lo) in enumerate(1:per:length(params))
        hi = min(lo + per - 1, length(params))
        ck = chunk_key(run, ci)
        SlateTask.write_chunk!(root, ck; fn_src = body_src, setup_src = setup_src,
                               captures = Dict(String(k) => v for (k, v) in captures),
                               params = params[lo:hi], keys = keys[lo:hi],
                               summary_src = summary_src, lazy = lazy, landed = landed)
        push!(chunks, ck)
    end
    BatchSweep.write_sweep!(root, run, chunks; cell = String(cell), notebook = _ctx_docid())
    # At most ONE unstarted run per cell. A run is keyed by body + setup + captures + grid, so every
    # edit to any of them mints a new one — and the old one, which nobody ever asked to run, is left
    # behind holding a blob per parameter point. An afternoon of adjusting a constant leaves a store
    # full of descriptors for work that was never requested.
    #
    # Starting is the line, and it is the right one: a started run may have jobs queued even with
    # nothing landed, so it survives. Anything that ran — even to a failure — has a manifest and
    # survives too. What goes is only ever a run nobody asked for that did nothing.
    _forget_stale_runs(root, run, String(cell))
    # The job cannot start without its descriptors, so they go over BEFORE anything is submitted.
    # Unchecked, a failed push submits work the far side cannot run: the chunk starts, finds no
    # descriptor for its key and dies there. An unreachable target pushes nothing and submits
    # nothing, which is how authoring against a cluster you are not signed in to keeps working.
    if sync_out!(target)
        _descriptors_sent!(target, run)
    elseif _reachable(target)
        error("could not send the sweep's descriptors to " *
              "$(target_host(target)):$(job_root(target)) — nothing was submitted")
    end

    launcher = launcher_for(target)
    # Running the cell RECONCILES; it does not submit. Authoring a sweep means running the cell
    # repeatedly, and every one of those must be free — the work starts when someone asks for it,
    # from the card. `submit = true` is for a standalone script, where there is no card to ask from.
    #
    # Keyed on THIS CALL's `submit`, never on whether the run happens to be started. Reading the
    # marker here meant a cell run resubmitted a sweep somebody had started at some point — and a
    # worker restart re-runs every cell, so reopening a notebook could start hundreds of units that
    # nobody asked for again. Starting says the work was wanted; it does not say this call should
    # start it. The card's poll advances a started sweep, which is where watching belongs.
    submit && BatchSweep.start!(root, run)
    reconcile_and_sync!(target, run, launcher; cap, submit = submit && _reachable(target),
                        failure_policy = sweep_policy(target))
    # Filled with the result below, so the card's settle report can bring the OBJECT level with what
    # the card already knows. A Ref because the channel is registered before the result exists.
    rref = Ref{Any}(nothing)
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
        # …and it carries WHAT the value now is, not just that it moved. The readers this wakes
        # recompute their memo keys on the way through, so without an identity for the results they
        # would key identically before and after the units landed and could restore an answer
        # computed against an empty sweep.
        note = (refresh === nothing || isempty(cell)) ? nothing :
               () -> refresh("cell:" * cell * "@" *
                             landed_digest(_rows(store_root(target), ps, ks, source_of(target))))
        # `advance` is honoured rather than assumed, so a caller that must not move the sweep can
        # say so. App mode pins it (`_app_channel_args`): a reader watching a card would otherwise
        # be submitting this sweep's outstanding chunks by polling it.
        register(status_channel(run),
                 a -> status_payload(target, run, ps, ks; plot,
                                     advance = get(a, :advance, true) !== false))
        register(action_channel(run),
                 a -> handle_action(target, run, ps, ks, String(get(a, :action, ""));
                                    plot, notify = note,
                                    landed = () -> (rref[] === nothing || refresh!(rref[])),
                                    arg = String(get(a, :arg, "")), opts = a))
    end

    pl = BatchSweep.plan(root, run; launcher)
    tl = BatchSweep.telemetry(root, run; launcher, plan = pl)
    rows = _rows(root, params, keys, run, source_of(target))

    # The same identity, for THIS run — declared rather than pushed, and computed from the rows just
    # read rather than a second pass over the store. The cell-effects channel is harvested with the
    # cell's result and applied by the hub before anything downstream is dispatched, which is the
    # ordering that matters: a reader computes its memo key on the way through, so the identity has
    # to be recorded by then or the reader keys against a sweep state that no longer exists. A
    # stream push would race that; this cannot.
    #
    # Read off the task-local execution context rather than imported, so this stays inert outside a
    # notebook (a standalone script, a test) with no coupling either way.
    let sctx = get(task_local_storage(), :slate_ctx, nothing)
        if sctx !== nothing && hasproperty(sctx, :effect)
            try; sctx.effect(:value_identity; digest = landed_digest(rows)); catch; end
        end
    end

    r = ShardedResult(key, run, target, collect(params), keys, pl, rows, tl, plot)
    rref[] = r
    return r
end

# Free names in the body that are bound in the calling module and look like DATA. These travel with
# the sweep as serialized captures.
#
# Functions, modules and types are excluded HERE because a compute node cannot revive a function
# value, only source — so they take the other route: `_helper_defs` finds the cell that defined one
# and ships its text through `setup_src`. Writing them out by hand in `setup =` still works and is
# what a definition with no notebook cell behind it needs.
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
        # A function, module or type cannot travel as a value, and neither can an open STREAM: in a
        # worker `stdout` is a capture object belonging to the worker's own module, so capturing it
        # ships a type the task process has never heard of and the unit dies in `deserialize_module`
        # naming a module the author never mentioned. Left alone, `stdout` resolves on the node to
        # the node's own — which is what a body writing to it meant.
        (v isa Function || v isa Module || v isa Type || v isa IO) && continue
        caps[n] = v
    end
    return caps
end

# ── Helpers the notebook defined ─────────────────────────────────────────────────────────────
# A function or struct cannot travel as a VALUE — a compute node has no way to revive one — so what
# travels is its SOURCE. `setup =` has always been the manual way to say that. This finds it
# instead: a name the body calls, which resolves to a function the NOTEBOOK defined, is looked up
# to the cell that defined it and that definition's text is folded into the setup.
#
# Going through `setup_src` rather than some new channel is the whole reason this is safe. The setup
# is digested into the sweep key, so editing a helper RE-KEYS the sweep — exactly as editing the
# body does — instead of quietly serving results computed by a version of the code that no longer
# exists. It also means a definition ships once per chunk rather than once per unit.
#
# Two facts make the lookup possible, and neither is new: a cell is evaluated under the filename
# `cell:<id>`, so a method defined there records that in `Method.file`; and `_eval_cell_source`
# keeps each cell's top-level statements under that same key (`__slate_cell_stmts`). A function
# from a package has no `cell:` file and is left alone — it is already installed where the unit runs.

# Does this top-level statement define `name`? `_def_name` already unwraps the forms a definition
# arrives in (short form, `function`, `where`, return-typed, `struct`, `const`, `macro`, and the
# docstring / `@inline` macrocall wrappers).
_stmt_defines(ex, name::Symbol) = _def_name(ex) == String(name)

"""
    _helper_defs(mod, names, param) -> (src, extra_names)

Source for every notebook-defined function, macro or type the body reaches, transitively, and the
DATA names those definitions themselves read — which have to travel as captures like any other.

The `using`/`import` lines of any cell a definition came from travel too. A helper is not
self-contained without them, and the author already wrote them next to it; requiring the sweep body
to restate the imports its helpers need would make this work only for helpers that need none. Only
cells actually drawn from are read, so an unrelated cell's plotting import is not shipped — but a
cell that imports something heavy for its OTHER statements will send that too, which is a reason to
keep a helper cell to its helpers.

Deterministic by construction: the sweep key digests this text, so an ordering that depended on
hash iteration would re-key the sweep at random and orphan every result it holds.
"""
function _helper_defs(mod::Module, names, param::Symbol)
    isdefined(mod, :__slate_cell_stmts) || return ("", Symbol[])
    stmts = try; getfield(mod, :__slate_cell_stmts); catch; return ("", Symbol[]); end
    found = Tuple{String,String,Int,String}[]      # (name, cell file, position, source)
    used = Set{String}()                           # cells at least one definition came from
    extra = Set{Symbol}()
    done = Set{Symbol}([param])
    queue = sort!(Symbol[n for n in names]; by = String)
    while !isempty(queue)
        n = popfirst!(queue)
        n in done && continue
        push!(done, n)
        isdefined(mod, n) || continue
        v = try; getfield(mod, n); catch; continue; end
        (v isa Function || v isa Type) || continue
        files = try
            sort!(unique(String[String(m.file) for m in methods(v)]))
        catch
            String[]
        end
        for file in files
            startswith(file, "cell:") || continue
            for (i, s) in enumerate(get(stmts, file, String[]))
                ex = try; Meta.parse(s); catch; continue; end
                _stmt_defines(ex, n) || continue
                # Shipped VERBATIM. The recorded statement is already the author's own text (see
                # `stmt_texts`), which is both what has to arrive on the compute node and what keeps
                # the sweep key stable — source carries no line numbers to shift.
                push!(found, (String(n), file, i, s))
                push!(used, file)
                # What the definition itself reads: helpers it calls (chased in turn) and data it
                # closes over. `_capture_names` binds the definition's own name and parameters, so
                # only genuinely free names come back.
                for m in _capture_names(ex, param)
                    m in done || push!(queue, m)
                    push!(extra, m)
                end
            end
        end
        sort!(queue; by = String)
    end
    sort!(found)
    # Imports first: a definition below may need them, and a module wants loading once per chunk.
    src = String[]
    for file in sort!(collect(used)), s in get(stmts, file, String[])
        ex = try; Meta.parse(s); catch; continue; end
        (ex isa Expr && ex.head in (:using, :import)) || continue
        s in src || push!(src, s)
    end
    for f in found; f[4] in src || push!(src, f[4]); end
    return (join(src, "\n"), sort!(collect(extra); by = String))
end

# Imports, then the helpers they may need, then what the author wrote, then a `script =` file.
_join_setup(parts...) = join(Iterators.filter(!isempty, (strip(String(p)) for p in parts)), "\n")

"""
    _script_src(mod, path) -> String

The source of a sweep's `script =` file, resolved the way `@asset` resolves a sibling (against the
notebook's asset base, so it works on a remote worker whose base is under `~/.cache`).

Returned as SOURCE rather than `include`d, because the source is what makes the file real to a
sweep: it travels to the compute node in the chunk descriptor, and it is digested into the sweep
key. An `include("model.jl")` in the body would do neither — the file would not be there, and
editing it would not invalidate anything, so the sweep would quietly serve results computed from a
version of the code that no longer exists.
"""
function _script_src(mod::Module, path)
    p = String(path)
    isempty(strip(p)) && return ""
    isdefined(mod, :__slate_readfile) ||
        error("@sweep: `script = \"$p\"` needs Slate's file resolver, which only exists inside a " *
              "notebook namespace. Pass the definitions with `setup = begin … end` instead.")
    return try
        String(Base.invokelatest(Base.invokelatest(getfield, mod, :__slate_readfile), p))
    catch e
        error("@sweep: could not read `script = \"$p\"` — " * first(sprint(showerror, e), 200) *
              ".\nThe path is resolved next to the notebook, like `@asset`.")
    end
end

"""
    @sweep grid [target] [setup=…] [chunk=…] do p
        …
    end

Run the body once per row of `grid`, as batch work, and return a [`ShardedResult`].

Belongs in a `#%% sweep` cell, and takes NO target there:

    #%% sweep id=scan cluster=hpc walltime=04:00:00
    scan = @sweep(paramgrid(n = 1:64)) do p
        simulate(p.n)
    end

The header is where the target and the resources live. `cluster=hpc` is a NAME, resolved by each
machine against its own registry — which is what lets one notebook run against a laptop's test
cluster and a site's real one with nothing edited in a cell. `walltime=`, `chunk=` and `data=` sit
beside it, and the ⚙ on the cell edits all of them without touching Julia source. That ⚙ is offered
on a sweep cell and nowhere else.

In an ordinary code cell this still runs, and is a worse version of the same thing: the target must
be written into the body, the header settings have nowhere to live, and nothing can be changed
except by editing code. Passing `target` is for a STANDALONE SCRIPT — a `.jl` run outside Slate,
where there is no header to read and no card to ask from. That is also the only place `submit=true`
belongs; in a notebook the work starts when someone presses Submit.

The body travels as SOURCE, so it must be self-contained apart from:

  * plain data from the notebook, which is captured and serialized automatically;
  * `using` / `import`, written in the body and lifted out to run once per chunk; and
  * functions, macros and types the NOTEBOOK defines — the cell that defined one is found and its
    source travels with the sweep, transitively, so an ordinary helper cell just works:

        # one cell
        stress(p) = p.β^2 / (1 + p.β)

        # another
        @sweep(paramgrid(β = 0:0.1:2), hpc) do p
            using MyPkg
            MyPkg.simulate(stress(p))
        end

    Editing that helper re-keys the sweep, exactly as editing the body does — it is part of what
    computed the results, so it is part of their identity. `setup = begin … end` still takes
    definitions written out by hand, which is what something with no cell behind it needs.

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
    # Hold the rest of the grid back until a unit has landed. `false` sends every chunk in the first
    # reconcile, which is what a re-run of a body you have already watched work wants — and it is
    # also what makes a sweep need nothing local once it is submitted, since there is no second wave
    # for anything to have to release.
    probe  = get(opts, :probe, true)
    # An unknown option is an error rather than a silent no-op: `@sweep(…, wallclock = "2h")` that
    # quietly does nothing is worse than one that says so.
    script = get(opts, :script, nothing)
    for k in keys(opts)
        k in (:setup, :cap, :submit, :resources, :plot, :summary, :lazy, :script, :probe) ||
            error("@sweep: unknown option `$k` " *
                  "(accepted: setup, cap, submit, resources, plot, summary, lazy, script, probe)")
    end

    # What the shard module needs before the body runs: the imports lifted out of the body, then
    # anything `setup` adds. `setup` takes Julia — a `begin … end` of helper definitions — rather
    # than a string, so it is parsed, highlighted and indented like the code it is.
    imports_src = join([string(im) for im in imports], "\n")
    user_setup = ""
    if haskey(opts, :setup)
        e = opts[:setup]
        user_setup = e isa AbstractString ? String(e) :                   # already source
                     (e isa Expr && e.head in (:block, :quote)) ?
                         string(_strip_lines(e.head === :quote ? e.args[1] : e)) :
                         string(_strip_lines(e))
    end
    # `summary` runs on the COMPUTE NODE, so like the body it travels as source. Given a one-argument
    # function it is stringified whole; given an expression it is wrapped as `v -> …`, so
    # `summary = sum(abs2, v)` reads the way it should.
    sumsrc = ""
    if haskey(opts, :summary)
        e = _strip_lines(opts[:summary])
        sumsrc = (e isa Expr && e.head === :(->)) ? string(e) : string("v -> ", string(e))
    end

    quote
        local _names = $(QuoteNode(sort!(collect(names); by = String)))
        # A helper the notebook defined travels as SOURCE, folded into the setup — so it ships AND
        # re-keys the sweep when it is edited. Its own free data names join the captures.
        local _helpers = $(Sweep)._helper_defs(@__MODULE__, _names, $(QuoteNode(param)))
        local _caps = $(Sweep)._collect_captures(@__MODULE__, vcat(_names, _helpers[2]),
                                                 $(QuoteNode(param)))
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
        # `script = "model.jl"` — the definitions the body calls, kept in a file instead of pasted
        # into the cell. Read HERE, at run time, so it resolves the way `@asset` does on whichever
        # side the cell is running; its SOURCE then rides `setup_src`, which both ships it to the
        # compute node and folds it into the sweep key. That last part is the whole point: a bare
        # `include` would leave the file unshipped and the key unchanged, so editing the script
        # would silently reuse results computed from the previous version.
        local _sscript = $(script === nothing ? "" :
                           :($(Sweep)._script_src(@__MODULE__, $(esc(script)))))
        $(Sweep).run_sweep($(Sweep).resolve_target($(esc(target)), _attrs, _clusters),
                           collect($(esc(grid))), $body_src;
                           setup_src = $(Sweep)._join_setup($imports_src, _helpers[1],
                                                            $user_setup, _sscript),
                           captures = _caps,
                           cap = $(esc(cap)), submit = $(esc(submit)), register = _reg,
                           probe = $(esc(probe)),
                           resources = $(esc(res)), plot = $(esc(plot)),
                           summary_src = $sumsrc, lazy = $(esc(lazy)),
                           refresh = _refresh, cell = String(_cell), attrs = _attrs)
    end
end

end # module Sweep
