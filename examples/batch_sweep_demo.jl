try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 🛰 Batch fabric: a sweep that outlives the notebook

A **parameter sweep** submitted as batch work, rather than run in this kernel. Shards execute in
separate processes, write their results into the content-addressed store, and this notebook reads
them back.

The point of the design is what happens when you *stop*: close the notebook, quit Slate, come back
tomorrow. Nothing is remembered in memory, so reopening asks the same three questions it always
asks and gets the same durable answers.

- **is this shard finished?** the store has a manifest for its key
- **is this chunk in flight?** the launcher has a live job under its name
- **did it fail?** the shard's manifest says so, with the traceback

This demo uses `ExecLauncher`, which runs shards as local subprocesses. The same cells work against
SLURM by swapping the launcher (see `dev/slurm-harness/`).
"""

#%% code id=load
# The batch fabric is plain includes for now: no package boundary yet, so this is the same source
# the compute nodes run.
#
# A notebook runs in a FORKED environment, so `Base.active_project()` is the fork and not the
# worktree that holds these sources. Ask the worker for its parent project first, and say plainly
# where we looked if none of the candidates has the file.
function _find_src()
    cands = String[]
    try; push!(cands, joinpath(Main.SlateWorker.PARENT_PROJECT[], "src")); catch; end
    try; push!(cands, joinpath(dirname(Base.active_project()), "src")); catch; end
    push!(cands, joinpath(homedir(), "devel", "KaimonSlate.jl", ".claude", "worktrees",
                          "feat+batch-fabric", "src"))
    for d in cands
        isfile(joinpath(d, "batchsweep.jl")) && return d
    end
    error("could not find batchsweep.jl. Looked in:\n  " * join(cands, "\n  "))
end

SRC = _find_src()

# `Base.include`, not a bare `include`: a notebook's module is built programmatically, so it has no
# `include` of its own the way a `module ... end` block would.
Base.include(@__MODULE__, joinpath(SRC, "batchsweep.jl"))

const BL = BatchLauncher
const BS = BatchSweep
SRC

#%% md id=h_store
@md"""
## The store

Everything lives under one content-addressed root. On a cluster this would be `/scratch`, visible
to every compute node; here it is a directory the subprocesses share.
"""

#%% code id=store
# The harness bind-mounts its `scratch/` directory as the cluster's /scratch, so the hub and the
# compute nodes see the SAME bytes at DIFFERENT paths. That is the shared-filesystem case the
# design assumes. A real remote cluster additionally needs the store adapter, which is not built
# yet: the hub would have no way to read a CAS it cannot mount.
HARNESS = joinpath(dirname(SRC), "dev", "slurm-harness")
ROOT  = joinpath(HARNESS, "scratch", "cas")   # the store, as the HUB sees it
RROOT = "/scratch/cas"                        # the same store, as a COMPUTE NODE sees it
mkpath(ROOT)
mkpath(joinpath(HARNESS, "scratch", "env"))   # an empty project for the task processes

# Ship the fabric sources across so the compute nodes can load them. On a real cluster this is what
# provisioning does; here the shared directory makes it a copy.
let dst = joinpath(HARNESS, "scratch", "src")
    mkpath(dst)
    for f in ("memostore.jl", "slatetask.jl", "batchlauncher.jl", "batchsweep.jl")
        cp(joinpath(SRC, f), joinpath(dst, f); force = true)
    end
end

(; hub = ROOT, node = RROOT)

#%% md id=h_grid
@md"""
## The parameter space

Twenty-four points, chunked six at a time. Chunking is not cosmetic: a Julia start plus package
load can dwarf a short shard, and a scheduler handles a few hundred array elements far better than
tens of thousands.

One parameter is rigged to throw, because a sweep where everything succeeds is not the interesting
case.
"""

#%% code id=grid
NSHARDS  = 24
PER      = 6
SWEEP    = "demo"

fn_src = """
p -> begin
    p == 7 && error("rigged failure: parameter 7 is bad")
    sleep(0.4)
    (p = p, y = sqrt(p) * 10)
end
"""

chunks = String[]
for (ci, lo) in enumerate(1:PER:NSHARDS)
    params = collect(lo:min(lo + PER - 1, NSHARDS))
    chunk = "$(SWEEP)_c$(ci)"
    SlateTask.write_chunk!(ROOT, chunk; fn_src, params,
                           keys = ["$(SWEEP)_s$(p)" for p in params])
    push!(chunks, chunk)
end
BS.write_sweep!(ROOT, SWEEP, chunks)
(; shards = NSHARDS, chunks = length(chunks))

#%% md id=h_submit
@md"""
## Submit

`reconcile!` works out what is missing and submits exactly that. Run this cell again at any time:
if everything has landed it submits nothing and returns immediately, which is what makes reopening
a notebook safe.
"""

#%% code id=submit
# Real SLURM. `SlurmLauncher` ssh's to the login node and runs sbatch there; the chunks go out as
# ONE array job, which is what array jobs are for.
launcher = BL.SlurmLauncher("slate-slurm")

# Every path inside the batch script is the COMPUTE NODE's view, which is why the spec takes RROOT
# while `reconcile!` below reads the store through the hub's own path.
spec = (name, cs) -> BL.JobSpec(name, cs;
    root      = RROOT,
    project   = "/scratch/env",
    payload   = "/scratch/src/slatetask.jl",
    resources = (; cpus = 1, mem = "512M", walltime = "00:10:00", partition = "compute"))

BS.reconcile!(ROOT, SWEEP, launcher, spec)

#%% md id=h_state
@md"""
## Where it stands

Five states, and the distinction between the last three matters. A sweep that finished with some
shards erroring is **`:partial`**: genuinely done, not still going, and not a total loss. A sweep
whose jobs keep dying without writing anything is **`:stalled`**, which needs a decision rather
than another resubmit.

Re-run this cell to watch it progress.
"""

#%% code id=plan
p = BS.plan(ROOT, SWEEP; launcher)

#%% code id=summary
(; state       = p.state,
   done        = "$(p.shards_done)/$(p.shards_total)",
   ok          = p.shards_ok,
   errored     = p.shards_failed,
   missing     = p.shards_missing,
   pct         = round(100 * BS.fraction(p); digits = 1),
   settled     = BS.is_settled(p),
   clean       = BS.is_complete(p),
   stuck       = BS.is_stuck(p))

#%% md id=h_results
@md"""
## Results as they land

`results` returns every shard, finished or not, so a partially complete sweep can still be
rendered. Shards that have not run carry `status = ""`.
"""

#%% code id=results
# This cell reads the STORE, not any notebook value, so Slate's dataflow analysis has nothing to
# invalidate it on when new shards land. Naming `p` makes it depend on the plan, so re-running the
# plan cell above refreshes this too.
#
# The eventual `slate_map` surface removes the awkwardness: the fan-out cell owns the value and
# downstream cells depend on it the ordinary way.
p

rs = BS.results(ROOT, SWEEP)
[(; r.key, r.status, r.ran_on, ms = round(r.ms; digits = 1)) for r in rs]

#%% code id=chart
p   # depend on the plan so this redraws when shards land (see the note on `results`)

# Only the finished, successful shards have a value to plot.
pts = [(r.value.p, r.value.y) for r in BS.results(ROOT, SWEEP) if r.status == "ok"]
sort!(pts; by = first)

echart(Dict(
    "backgroundColor" => "transparent",
    "title"   => Dict("text" => "sqrt sweep — $(length(pts)) of $NSHARDS shards on SLURM"),
    "tooltip" => Dict("trigger" => "axis"),
    "xAxis"   => Dict("type" => "value", "name" => "p"),
    "yAxis"   => Dict("type" => "value", "name" => "y"),
    "series"  => [Dict("type" => "line", "showSymbol" => true, "smooth" => true,
                       "data" => [[x, y] for (x, y) in pts])],
))

#%% md id=h_failures
@md"""
## Which ones broke

The answer to "47 of my 10,000 jobs failed and I do not know which". Each failure carries its
parameter and its traceback, and the successful shards are untouched.
"""

#%% code id=failures
p   # depend on the plan so this refreshes when shards land (see the note on `results`)

BS.failures(ROOT, SWEEP)

#%% md id=h_retry
@md"""
## Retrying

Errors are **not** retried automatically: a shard that threw will usually throw again, and quietly
re-running thousands of them wastes an allocation on a deterministic bug. Retrying is a decision.

Un-comment and run to clear the failed entries, then re-run **Submit** above.
"""

#%% code id=retry
# BS.retry_failed!(ROOT, SWEEP)
"(disabled — un-comment to retry the failures)"

#%% md id=h_reset
@md"""
## Start over

Drops every manifest for this sweep and its submission history, so the next reconcile runs the
whole thing again from cold.
"""

#%% code id=reset
function reset_demo!()
    for c in BS.sweep_chunks(ROOT, SWEEP), k in BS.chunk_shards(ROOT, c)
        MemoStore.drop_manifest(ROOT, k)
    end
    BS.clear_attempts!(ROOT, SWEEP)
end
"(call reset_demo!() to clear)"

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 9204132c-0a77-4c07-8135-f06cb33aba84
# ╚═╡
