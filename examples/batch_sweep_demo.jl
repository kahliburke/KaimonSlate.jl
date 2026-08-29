try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 🛰 A sweep that runs on a cluster

A parameter sweep submitted to **real SLURM**, from this notebook.

The problem this exists to solve is not that a sweep is hard to launch. It is that a long run is
opaque: a pill reading *"running… 4302 seconds elapsed"* tells you nothing about whether it is
working, how far along it is, how much longer to wait, or whether it quietly stopped. And when
something does go wrong, the half hour already spent is usually gone with it.

So every unit of work here is content-addressed and stored on its own. That one decision buys:

- **progress and an honest ETA**, measured from completions rather than guessed
- **partial results**, usable while the rest is still running
- **resumption** — a killed or preempted unit re-runs, a finished one never does
- **failure isolation** — a bad parameter is recorded, it does not take the run down
"""

#%% code id=load
# The batch fabric, loaded from the worktree.
function _find_src()
    cands = String[]
    try; push!(cands, joinpath(Main.SlateWorker.PARENT_PROJECT[], "src")); catch; end
    try; push!(cands, joinpath(dirname(Base.active_project()), "src")); catch; end
    push!(cands, joinpath(homedir(), "devel", "KaimonSlate.jl", ".claude", "worktrees",
                          "feat+batch-fabric", "src"))
    for d in cands
        isfile(joinpath(d, "sweep.jl")) && return d
    end
    error("could not find sweep.jl. Looked in:\n  " * join(cands, "\n  "))
end

SRC = _find_src()

# Loaded into `Main`, not into this notebook's module: `using` binds the name here as an IMPORT, and
# a module cannot then be defined under it.
#
# Guarded, and it has to be. Re-including builds a SECOND `Sweep` module, and `using` then sees two
# modules exporting the same names, so every one of them becomes ambiguous. While developing the
# fabric itself, picking up a source change means restarting the extension.
isdefined(Main, :Sweep) || Base.include(Main, joinpath(SRC, "sweep.jl"))
using Main.Sweep

SRC

#%% md id=h_target
@md"""
## Where it runs

A **target** says where units execute and how the two sides see the store. It is the only thing
that changes between a laptop and a cluster: the sweep cells below are identical either way.

`root` is the store as this notebook sees it; `root_remote` is the same store as a compute node
sees it. The harness bind-mounts one directory into both.
"""

#%% code id=target
HARNESS = joinpath(dirname(SRC), "dev", "slurm-harness")
DEMOPKG = joinpath(dirname(SRC), "dev", "sweepdemo")     # the science, as a real package

for d in ("cas", "env", "src"); mkpath(joinpath(HARNESS, "scratch", d)); end
for f in ("memostore.jl", "slatetask.jl", "batchlauncher.jl", "batchsweep.jl")
    cp(joinpath(SRC, f), joinpath(HARNESS, "scratch", "src", f); force = true)
end

# How long each unit takes, and how many there are. Small while iterating on the mechanism; raise
# them to exercise what a genuinely long run does (queue waits, ETA accuracy, stall detection,
# walltime kills). Both are CAPTURED by the sweep bodies below, so changing either one re-keys the
# sweep and starts a new one rather than mixing results across settings.
COST  = 0.05     # seconds per unit
NSCAN = 40       # units in the full sweep

hpc = SlurmTarget("slate-slurm";
    root        = joinpath(HARNESS, "scratch", "cas"),   # as the HUB sees it
    root_remote = "/scratch/cas",                        # as a COMPUTE NODE sees it
    project     = "/scratch/env",
    payload     = "/scratch/src/slatetask.jl",
    chunk       = 10,
    resources   = (; cpus = 1, mem = "512M", walltime = "00:10:00", partition = "compute"))

# The local target PREPARES its task environment from a parent project, seeded by the same policy
# the notebook fork and the remote provisioner use. Here the parent is the SweepDemo package, so a
# task process loads the science and nothing else — not this notebook's plotting packages, which a
# compute node has no use for and which cost startup time and memory on every unit.
local_target = LocalTarget(;
    root   = joinpath(homedir(), ".cache", "kaimonslate", "sweepdemo"),
    parent = DEMOPKG,
    chunk  = 10)

(; task_env = local_target.project, COST, NSCAN)

#%% md id=h_module
@md"""
## Sweeping code from a project, not from the notebook

The realistic shape: the science lives in a **package** (`dev/sweepdemo`), which is provisioned to
the task environment, and the sweep body is a one-line call into it. Nothing about the body has to
be serialized or shipped — the package is simply a dependency of the environment the task runs in.

That also keeps the task environment small: it has SweepDemo and its dependencies, and none of the
plotting or display packages this notebook uses, which a compute node has no use for.
"""

#%% code id=module_sweep
by_module = @sweep(paramgrid(x = 0:0.25:8, seed = 1:2), local_target;
                   setup = "using SweepDemo") do p
    SweepDemo.work((; x = p.x, seed = p.seed, ms = 20))
end

#%% md id=h_pilot
@md"""
## Pilot first

Before spending an allocation, run a handful of points and look at the output. Because every unit
is keyed by content, **these results are kept**: the full sweep below reuses them rather than
recomputing, and it is the same code path because only the grid changed.
"""

#%% code id=pilot
pilot = @sweep(paramgrid(x = 1:4), hpc) do p
    sleep(COST)
    (x = p.x, y = exp(-0.15 * p.x) * cos(3 * p.x))
end

#%% md id=h_sweep
@md"""
## The full sweep

Forty units. Re-run this cell to refresh: it reconciles against the store and the scheduler and
submits only what is missing. Once everything has landed it returns immediately having submitted
nothing, which is what makes reopening this notebook safe.

One parameter is rigged to throw, so the failure path is visible rather than theoretical.
"""

#%% code id=scan
scan = @sweep(paramgrid(x = 1:NSCAN), hpc) do p
    sleep(COST)
    p.x == 13 && error("rigged failure: parameter 13 is bad")
    (x = p.x, y = exp(-0.15 * p.x) * cos(3 * p.x))
end

#%% md id=h_progress
@md"""
## Progress

Re-run the sweep cell to watch this move. `:partial` is a **finished** state, not a broken one:
every unit reached a terminal outcome and some of them errored.
"""

#%% code id=progress
(; state      = scan.plan.state,
   done       = "$(scan.plan.shards_done)/$(scan.plan.shards_total)",
   ok         = scan.plan.shards_ok,
   errored    = scan.plan.shards_failed,
   remaining  = scan.plan.shards_missing,
   rate_per_s = round(scan.telemetry.rate_per_s; digits = 2),
   eta_s      = round(eta(scan); digits = 1),
   idle_s     = round(scan.telemetry.idle_s; digits = 1),
   stuck_for  = stalled_for(scan),
   blocked    = blocked(scan))

#%% md id=h_results
@md"""
## Results, usable while incomplete

`finished` returns only the units that succeeded, so a plot can render a partial sweep without
having to decide what a missing point looks like.
"""

#%% code id=chart
pts = sort([(row.value.x, row.value.y) for row in finished(scan)]; by = first)

echart(Dict(
    "backgroundColor" => "transparent",
    "title"   => Dict("text" => "damped oscillation — $(length(pts)) of $(length(scan)) units"),
    "tooltip" => Dict("trigger" => "axis"),
    "xAxis"   => Dict("type" => "value", "name" => "x"),
    "yAxis"   => Dict("type" => "value", "name" => "y"),
    "series"  => [Dict("type" => "line", "showSymbol" => true, "smooth" => true,
                       "data" => [[x, y] for (x, y) in pts])],
))

#%% md id=h_where
@md"""
## Where each unit ran

Provenance per unit: which node, which job, which array element.
"""

#%% code id=where
[(; row.params.x, row.status, row.ran_on, ms = round(row.ms; digits = 1))
 for row in scan.rows][1:min(12, length(scan))]

#%% md id=h_failures
@md"""
## Which ones broke

The answer to "47 of my 10,000 units failed and I do not know which". Each failure carries its
parameters and its traceback, and the successful units are untouched.

Errors are **not** retried automatically: a unit that threw will usually throw again, and quietly
re-running thousands of them spends an allocation on a deterministic bug. `retry_failed!(scan)`
clears them, then re-run the sweep cell.
"""

#%% code id=failures
[(; row.params, err = first(String(row.value), 120)) for row in failures(scan)]

#%% md id=h_breaker
@md"""
## The circuit breaker

The failure worth designing against: submit thousands of units, wait a day, discover the body was
broken all along. A sweep that is failing early stops itself rather than spending the rest of the
allocation proving the same point.

This one runs locally so it costs nothing to demonstrate.
"""

#%% code id=breaker
# 60 units, of which only the first probe chunk will ever run. Local task processes are bounded by
# `ExecLauncher`'s process limit, so this costs a handful of Julia starts, not sixty.
broken = @sweep(paramgrid(x = 1:60), local_target) do p
    error("typo in the body: no method matching frobnicate")
end

#%% code id=scale
# Scaling: the tile grid BINS units to a fixed budget, so the display costs the same at ten units
# and at ten million. Failure clustering survives binning — a bad region of the parameter space
# still shows as a red band rather than dissolving into an average.
big = @sweep(paramgrid(x = 1:4000), local_target) do p
    # A whole region of the parameter space is broken, which is what clustering should reveal.
    2200 <= p.x <= 2600 && error("bad region")
    p.x
end

#%% md id=h_reset
@md"""
## Starting over

`reset!(r)` drops every unit for a sweep and its submission history, so the next run goes from cold.
"""

#%% code id=reset
"(call reset!(scan) or reset!(broken) to clear)"

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = c9a73fa9-f90e-4907-947b-04344d988ea2
# ╚═╡
