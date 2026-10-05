# Clusters — batch sweeps and interactive nodes

A cluster is two different machines wearing one name, and Slate treats it that way.

One is **fire-and-forget**: you submit a few thousand parameter combinations, close your laptop, and
come back to results. That work has to outlive the notebook, because it will run for longer than you
will sit there. The other is the opposite — a **live session** on a compute node that you poke at,
re-run, and change your mind about. That one has to be interactive, and it needs to be *on a compute
node*, not on the login node everyone shares.

Slate does both, and they share one authenticated connection, one store, and one set of results:

| | Batch sweep | Interactive region |
| --- | --- | --- |
| A cell says | `#%% job cluster=hpc` | `#%% code region=gpu` |
| Runs as | scheduler jobs | a live Slate worker |
| Outlives the notebook | yes | no |
| Where the work goes | wherever the queue puts each job | one node, held for a walltime |
| Results | land in a store, read back on demand | ordinary values in the namespace |

Both are configured on the front page, under **🖧 Remotes** — a cluster describes a *machine*, and a
notebook that names one carries only the name.

## Defining a machine

**🖧 Remotes → Machines** on the front page. A machine is what a `#%% job cluster=<name>` cell
submits to, and what a region runs its workers on when it names one:

| Field | What it is |
| --- | --- |
| **Name** | what a cell writes as `cluster=…`. A plain identifier — it goes in a cell header. |
| **Kind** | What *schedules* the work: `slurm`, `pbs`, or `exec` — no scheduler at all, Slate starting the processes itself. |
| **Host** | where the work runs. For `slurm`/`pbs` it is the node you submit from, and Slate offers the queues it reports. For `exec` it is optional: blank runs on this machine. |
| **Store** | a path **on the machine the work runs on** (this one, if Host is blank). On a cluster put it on scratch: `$HOME` is a few tens of GB and is not built for parallel writes. |
| **Partition / walltime / cpus / mem** | what each job asks for. A cell may override any of them. |
| **Project** | the local project the units run in. Blank is the notebook's own, which is almost always what you want: its exact Manifest is what the tasks get. |
| **Depot** | where Julia keeps packages and compiled code on that machine. Blank is automatic: the site's scratch filesystem, found when the machine is prepared, else `~/.julia`. |
| **Chunk** | how many sweep units ride one scheduler job. |
| **At once** | `exec` only: how many tasks run in parallel on that machine. Blank follows the setting below. |
| **Prologue** | shell run before every Julia on the machine, a region's worker as much as a job. |
| **Julia** | a julia binary to use. Blank installs juliaup at the hub's Julia version, so results and environments carry across. |
| **Test QoS** | the queue for the test task a sweep runs first (see [Preparing](#Preparing-a-machine-or-a-region)). `debug` on most sites. |
| **Mode** | who may read the store, as an octal directory mode. `0700` (the default) is yours alone; `0750` lets your unix group read it; blank follows the site's own umask. |

### The shell every Julia starts in

Everything a machine says about running Julia is applied in one place, to every Julia started there:
a region's worker, the build of an environment, Prepare's checks and each task of a sweep. Julia goes
on the `PATH`, the depot becomes the first entry of `JULIA_DEPOT_PATH`, the module fix Prepare found
runs (on Perlmutter, unloading the `cudatoolkit` module that puts the system's CUDA libraries ahead
of CUDA.jl's), then your prologue.

The depot matters more than it looks. On a shared home filesystem every package load checks its
compiled cache against the source files one metadata lookup at a time, which can double the time
`using CUDA` takes compared with scratch, warm or not.

### Who can read a sweep

A store holds the results, the job output, and the source of the body that produced them — including
whatever the closure captured on its way to the cluster. It also lives on scratch, which is outside
whatever protection your home directory has, on a machine with everyone else's accounts on it.

So Slate creates it `0700` and runs every process that writes into it under a matching umask. Set
**Mode** to `0750` if your site puts collaborators in a project group and you want them to read your
runs, or blank to follow the site's default — which on most clusters is world-readable.

This is about the filesystem. Who can *talk to* a worker is a separate question, answered by CURVE
and an allow-list holding only your hub's key; see [Remotes](remotes.md).

### No scheduler

`exec` is the absence of a scheduler, not a place. `kind` says what schedules the work and **Host**
says where it runs, so the two are independent: blank host runs here, and a host with no queueing
system on it — a lab workstation, a cloud VM — is a target like any other. Slate starts the
processes over that machine's session, watches them by pid, and kills them on cancel; the store,
the environment and the task runner are provisioned exactly as they are for a cluster.

(`local` is the older spelling of `exec` with no host. Definitions using it keep working.)

An `exec` target has no scheduler deciding how much of the machine it may take, so Slate does. Each
task is a whole Julia loading the project, which makes memory rather than cores the binding
constraint, and the default is well under the core count for that reason. A workstation with room to
spare can say so once for every local target on this machine:

```julia
KaimonSlate.set_local_procs!(8)     # 0 restores the machine default
```

A target's own **At once** outranks it.

The **name is the contract, not the address**. A notebook says `cluster=hpc`, and each machine that
opens it resolves that against its own registry — which is what lets the same notebook run against a
laptop's test cluster and a site's real one with nothing edited in a cell. It is also why a target
you have not defined produces an error naming the ones you have, rather than a silent local run.

## Sweeping

```julia
#%% job id=scan cluster=hpc walltime=04:00:00
results = @sweep paramgrid(; n = 1:64, seed = 1:20) do p
    simulate(p.n, p.seed)
end
```

Note what the `@sweep` call does **not** say: where the work runs. That is `cluster=hpc` on the
header, so the cell names a target rather than addressing one, and the ⚙ changes it without touching
Julia. Make the cell a **Job** cell (the kind picker on the cell, or `#%% job`) — `@sweep`
runs in an ordinary code cell too, but there the target has to be written into the body, `walltime=`
and `chunk=` have nowhere to live, and there is no ⚙ to change any of it. Passing a target
positionally is for a standalone `.jl` outside Slate, where there is no header to read.

The cell is a **reconciler**, not a submit button. Running it again submits only what is missing: it
never recomputes a unit that has already landed. That is what makes the header attributes safe to
edit — resources are not part of the sweep's identity, so raising a walltime *resumes* the sweep
rather than discarding the units that already finished.

Running the cell never spends anything. It prepares the sweep — descriptors written, plan computed —
and the card reads **ready**. Pressing **Submit** *starts* it, and from then on the card keeps
submitting what is missing until it finishes or you cancel. `submit = true` on the `@sweep` call
skips that approval, and is meant for a script with no card to ask from.

Because it reconciles, the honest thing to do with a job cell is run it repeatedly. It tells you
what is queued, what is running, what landed, and what failed its attempt budget.

The body travels as **source**, because a compute node cannot revive a function value. That is
invisible in the ordinary case: data in notebook variables is captured and shipped, `using` is
written in the body and lifted out to run once per job, and a function, macro or struct the notebook
defines is traced to the cell that defined it and travels too — transitively, so a helper that calls
a helper works. Editing one **re-keys the sweep**, exactly as editing the body does: it is part of
what computed the results, so it is part of their identity.

### Output too large to bring back

`data=auto` on the cell header stores a unit's result **addressably** — chunked and indexed where it
ran — so the notebook holds an index of kilobytes and a slice moves only the bytes it names.

For output that never becomes a Julia value at all — a solver writing HDF5 or NetCDF from somewhere
inside itself — return `adopt(path)` instead. The file is read on the compute node that wrote it and
re-emitted in the same addressable form, so nothing extra crosses the wire:

```julia
#%% job id=runs cluster=hpc data=auto
runs = @sweep paramgrid(; day = 1:365) do p
    using NCDatasets
    f = @sfile("grid_$(p.day).nc")
    simulate_into(f, p)
    adopt(f)
end
```

A file holds several named variables, so an adopted one is a **group**: `keys(runs.dataset)` names
them, `runs.dataset[:sst]` hands back an ordinary dataset to slice, and the dimension names and
attributes the format carried come with it. Write files under `datadir()` or `@sfile`, which resolve
on the node the way they do in the notebook — the per-region scratch, beside the job.

## Working on a compute node

A region whose host is a cluster's front door does not run there. `login` is where you **ask**; the
node is what you are **given**, and which node is an output of the allocation — it does not exist
until the scheduler grants it.

So a cluster region stores what to ask for rather than an address:

| Field | What it is |
| --- | --- |
| **Scheduler** | `none` (run on the host itself), or the one to use. Slate detects what a host has and offers it; the choice stays yours, because a site can have both toolsets installed with only one running the jobs, and a login node you are content to run a small worker on is a legitimate answer too. |
| **Partition** | picked from the queues the host reported, with down queues shown as down. |
| **Walltime** | how long to hold it. The most important field on the form: an allocation bills for the time it is **held**, not the time it is used. |
| **cpus / mem / gpus / account** | the rest of the request. A region on a machine fills any it leaves blank from the machine's. `mem = default` sends no memory request, so the queue's own default applies. |

On SLURM, **Request with** decides how the node is asked for. `sbatch`, the default, submits a job
that holds the node. `salloc` asks for an interactive allocation, which a site's interactive QOS
requires: it refuses submitted jobs, and it usually starts far sooner than a shared or regular one. A
request through `salloc` waits on the login node it was made from until the node is granted, so it is
lost if that login node goes down while it waits.

`mem = 0` asks SLURM for all of a node's memory, and SLURM adds CPUs to cover memory, so on a shared
queue it turns a request for one GPU into a request for the whole node. When the scheduler holds more
CPUs for a job than the region asked for, the prepare step and the queued line say so.

**Warm workers are not offered on a scheduler region.** They exist to skip the boot by keeping a
worker on the host between notebooks, and a scheduler region has no such host — its node is an
allocation, and the next one may be a different machine. Keeping workers alive is also what stops an
idle node being released, so a region with them holds and bills for one until its walltime expires.

The first cell tagged for the region asks the scheduler and waits for a node. A busy queue is
reported rather than hidden — the request stands, and running the cell again attaches to it. It is
found by job name, so reopening the notebook lands on the node you were already using instead of
queueing for a second one.

A cluster you cannot reach at all says so in those words, rather than as a queue that is taking its
time: the two look identical from here — no node either way — and only one of them is about the
scheduler.

A compute node is normally not reachable from your laptop at all, only through the login node. Slate
registers that route the moment it learns which node it got, so everything after — the worker, the
tunnel, file sync — goes the two hops without being told.

**Giving it back.** The Remotes modal shows what a region is holding (node, job id, time left) with a
**Release** button. A region that drains to no workers releases on its own, and deleting a region
always does. The commonest way to waste a cluster is an allocation nobody remembers.

## Authenticating once

Plenty of production clusters refuse public keys. You get a password and a second factor, and that is
the only way in.

Slate speaks SSH itself rather than driving the `ssh` command, so the server's `keyboard-interactive`
prompts arrive as values it can hand to you: a dialog appears in the page for each thing the server
asks, in the server's own wording. The same path handles a password, a numeric code, a Duo menu, or a
push that takes a while. Nothing about it is scripted, and Slate never sees your second factor before
you type it.

**One session per host, and everything rides it.** Sweeps, regions, provisioning, file transfer,
byte-range reads and port forwards are all channels on that one connection, so a cluster that costs a
2FA prompt costs exactly one — not one per subsystem. A compute node is reached *through* its login
node for the same reason: a session to the node itself would be a second authentication.

The sessions live in the **hub**, not in a notebook's worker, so one sign-in covers every notebook on
the machine — its sweeps *and* its regions. A worker that needs a cluster asks the hub rather than
opening its own connection.

**Signing in is something you do, never something that happens to you.** Only a deliberate act starts
it — the padlock at the top of the page (or ⌘K → *"Sign in to a host"*), or `Sweep.connect!(host;
interactive = true)` from a cell. Opening a notebook, reconciling a sweep and polling a roster all run
against a session that already exists and say "not signed in" otherwise. Without that split, the first
dialog you saw would come from whichever background poller got there first, on a page with nothing on
it to explain the question.

The panel lists **hosts**, not clusters, because wanting a password is a property of the host's sshd —
a cluster can take keys and a plain remote can demand 2FA. Each row shows what uses it (which compute
targets, which regions) and whether it is signed in. **Check** asks the host which authentication
methods it offers *without* authenticating, so it costs no failed login on a server that penalises
those.

## Preparing a machine or a region

A region's first worker on a new machine runs into everything about that machine at once: Julia to
install, the worker's own packages, modules the site loads by default, a filesystem slower than a
laptop's. **Prepare** does that work on its own, outside any notebook, and reports each step. It
comes in layers:

* **A machine** (its Readiness row under 🖧 Remotes → Machines, or `machine(name=…, action="prepare")`):
  sign in, Julia, read the site, settle the depot. What it finds belongs to the host, so every region
  and sweep there uses it.
* **A region** (its Readiness row, or `region_prepare(name)`): the machine's steps, then the node.
* **A sweep's environment** (the **Prepare** button on a sweep card that has not run on the machine
  yet, or `machine(name=…, action="prepare_batch", project=…)`): the machine's steps, then the
  notebook's task environment is built on the machine and **one test task** goes through the
  scheduler, asking for the sweep's node type for a few minutes on the machine's **Test QoS**. It
  precompiles there, loads every package and checks CUDA. Until that has passed, the sweep submits
  nothing: a broken environment costs one short job rather than every task of the array.

A region's prepare does this:

* sign in, install Julia at the hub's version, build the worker runtime;
* read the site: CPU, default modules, CUDA libraries on the library path, Julia version;
* create the data root and check it is writable;
* on a scheduler region, the first time: get a node, read it the same way, check that it sees the
  login node's files, time loading the worker runtime and the region's preload environment there,
  check CUDA, and give the node back.
* on a region with **sysimage** on, build its workers' sysimage where they run (the node, on a
  scheduler region) and in the machine's shell, after the packages are precompiled. The step says
  whether the image was built, was already current, or was put off and why (too little free memory,
  another build running, no C compiler). `region_prepare(name, sysimage="rebuild")` builds it again
  even when it is current.

### What a region's sysimage holds

The region decides what its image holds: its Prepare dialog lists the packages. The list starts as the preparing notebook's
registered packages and its project's, and you can add any registered package, choose a release for
each (the newest is marked), or add a package from a path on the machine. Slate's own worker
packages are always in it. A package the notebook has from a path, its project included, is never
baked: it loads on top of the image, so editing it takes effect as it would without one.

Julia loads a package from the image whatever version a notebook's environment asks for. So a
worker boots from the region's image only when every package the two share is the same version in
both; otherwise it starts without it and says which package differs. A package only the image holds
loads in the region's cells, but not on this machine. Each package takes the version the preparing
notebook resolves, unless the list chooses one.

Images live in the machine's depot under `slate-sysimg/`, each named by a hash of Julia's version
and every package it holds, with one image file per CPU the nodes have. Regions whose lists resolve
to the same packages use the same image, so a second region on a machine often finds its image
already built. An image no region uses any more stays on disk until it is deleted.

What it finds is kept with the region and used by every start after it. A module that puts the
system's CUDA libraries ahead of CUDA.jl's is unloaded before the worker starts. The time loading took
sets how long a worker may go silent before its connection is dropped (a region's own **Liveness**
setting overrides it). And each start compares Julia and the default modules with what was recorded:
when they differ the region is marked stale, and Prepare again brings it up to date.

A notebook's packages loading on a machine's nodes is recorded once, with the machine, for that kind
of node (its partition and constraint). A region's prepare and a sweep's test task both write it, and
the same record decides for both: a region on those nodes needs no prepare of its own for a project a
sweep has tested there, and a sweep goes out without a test once a region has loaded its project
there. Either one waits when the machine's site has changed since it was prepared, when the packages
have changed since they were tested, or when nothing has loaded them on that kind of node yet.

A region cell in that position waits and offers **Prepare**. Prepared from the notebook, the region also installs and
precompiles those packages where the workers run, then starts the notebook's own worker and loads
them in it. The node and that worker stay for the notebook, and the waiting cells run on it when the
prepare ends. While a region is being prepared, its cells wait for it rather than start a worker of
their own beside it.

## Waiting for a node

A region on a scheduler does not have an address until the scheduler grants one, and on a busy cluster
that wait is minutes. Running a region cell asks for a node and says so; the cell then **runs itself**
when the node lands, along with anything downstream of it. The region's pill reports `queued` for the
duration, and the bring-up narrates into the banner — a cold region installs the notebook's whole
environment on the far side, which is real work that should not look like nothing happening.

The allocation is found by job name, so reopening the notebook attaches to the node it was already
using instead of queueing for a second one.

Opening a notebook never asks for a node. A node bills from the moment it is held, so the run that
opening starts leaves region cells reading **run to request a node** when nothing is held, and
running them asks. A node that is already held is used straight away.

A held node with nothing running on it still bills until its walltime. Set the region's **idle
release** (`10m`, say) to give it back after that long without a region cell running, and **idle
warn** to be asked first.

## Reading results back

Slate does not assume it can see the cluster's filesystem — the normal deployment is a laptop driving
a cluster it has no mount on. So:

* **Metadata is mirrored.** Manifests and status are copied into a local shadow in one round trip, so
  asking what a sweep is doing costs the new manifests and nothing else.
* **Data stays put.** A unit's results are read by byte range over the same session.
  With `data=auto` a slice costs the bytes it names rather than the whole result.

### One view of the output

`results.dataset` is what you read, whatever the units returned. Every grid point is in it: a unit
that returned one row contributes one, a unit that returned many contributes all of them, and a unit
that has not landed contributes a row of `missing`, so the holes sit where the work still is.

```julia
results.dataset                            # schema, rows, size; reads no data
results.dataset[1:1000]                    # a bounded slice, parameters attached
results.dataset[1:1000, (:snr, :status)]   # ...and only these columns
Sweep.scan(results.dataset; between = (:snr, 3, Inf), where = row -> row.seed != 7, limit = 10_000)
Sweep.query_cost(results.dataset)          # what a read would cost, before making it
```

Whether a unit's rows were chunked into the store or carried inline in its manifest is a storage
decision, and none of the above changes with it. `status`, `ms`, `ran_on` and `at` are left out of
the default columns because they repeat down a unit's whole block; name them to get them.

Which is why the last step is unremarkable: a batch result and a value from an interactive worker are
both just values in the notebook's namespace, and combining them is ordinary Julia.

## Logging from a sweep

Write with **`@info`, `@warn` and `@error`**, not `println`. The task runner installs a logger for
them, so a record carries its level, when it happened, and where it came from, and keyword values
sit beside the message rather than inside it:

```julia
#%% job id=runs cluster=hpc
runs = @sweep paramgrid(; case = 1:500) do p
    @info "starting" case = p.case
    r = solve(p.case)
    r.residual > 1e-3 && @warn "did not converge" case = p.case residual = r.residual
    r
end
```

```
┌ Info 14:22:31.004: starting
│   case = 3
└ @ Main cell:runs:2
```

A record **declares** its level, and that is believed over its wording — an `@info` that mentions a
failure stays info, so filtering a log to `error` gives you what went wrong rather than every line
containing the word. Output that declares nothing — a bare `println`, a C library, the scheduler's
own messages — is classified by its wording instead, which is the best that can be done for it.

Colour is on: the stream is a file, so nothing can detect a terminal, and the viewer renders what
the logger emits.

## Reading a job's output

The failures that cost the most time leave **no manifest** — an OOM kill, a walltime cut, a prologue
that failed — so `results.errors` is empty and the only account of what happened is what the job
printed. **Logs** on a sweep card opens it.

The viewer never holds a file, only a window onto one, so a job that printed a gigabyte opens as
fast as one that printed a line:

| | |
| --- | --- |
| **The file list** | every element of every job in the sweep, sortable by time, size or name, filterable by name. Switch sweeps from the menu in the header to read another cell's jobs without closing it. |
| **Levels** | `all` / `info` / `warn` / `error`, counted over the **whole file** — "error 40" means the file holds forty, not forty of what is on screen. |
| **Search** | over the whole file too, wherever it lives, with ▲▼ to walk the matches. A match past the end of the window is found and jumped to without reading what precedes it. |
| **Follow** | a growing file is re-read every few seconds while you are at the end that grows; **pause** stops it, and scrolling away shows *new output* rather than moving the text under you. |

Newest content is at the top by default. Flip it with **oldest first** when you are reading a
traceback, which is written downwards.

The same files are reachable from Julia when you would rather grep than scroll:

```julia
Sweep.log_files(results)                       # what there is
Sweep.log_search(results, path, "OOM")         # the whole file, wherever it lives
Sweep.log_slice(results, path; offset = -4096) # the last 4KB
Sweep.logs(results)                            # every job's tail, headed by job
```

## SLURM and PBS

A target's **Kind** picks the scheduler, and it is the only thing about a cluster that changes:
sweeping, regions, provisioning, the store and the notebook itself are identical either way.

The settings are not a renaming exercise, though, and Slate does not pretend they are:

* **PBS asks for per-node resources inside a chunk statement.** `cpus`, `mem`, `gpus` and
  `ntasks_per_node` become `-l select=N:ncpus=…:mem=…:ngpus=…:mpiprocs=…`, and `nodes` is the chunk
  count. Sizes are rewritten to PBS's spelling on the way (`16G` → `16gb`).
* **`select=` is the escape hatch.** Write the chunk statement yourself and it wins outright — which
  is how a site resource Slate has no name for (`scratch_local`, a node feature, a specific host)
  gets asked for. Job-wide options go in the definition's **directives**, verbatim, as `#PBS` lines.
* **A setting one scheduler cannot express is an error, never a silent drop.** `constraint`, `gres`,
  `nodelist`, `exclude`, `reservation`, `mem_per_cpu` and `ntasks` have no PBS equivalent, and
  `select` has no SLURM one. Each says so and names the way to ask for the same thing there. The
  cell editor greys them out for the cluster the cell points at, and relabels the rest.
* **Anything Slate has never heard of still works.** On SLURM a setting becomes `--key=value` with
  `_` → `-`; on PBS it becomes `-l key=value` as written, because PBS resource names carry
  underscores.

Two differences are worth knowing about because they are visible:

* **A PBS job's log appears when the job ends.** PBS spools stdout on the execution node and copies
  it back at exit, where SLURM writes it live. Per-unit progress comes from the store either way, so
  this only affects reading the raw log of something still running.
* **A compute node is reached by ssh from the login node.** SLURM has `srun --overlap`, which joins
  a running allocation without logging in again; PBS has nothing equivalent, so it uses the hop
  every PBS site already relies on. The hub still authenticates once — that ssh is issued *on* the
  login node's session — but the site has to permit it, which is the usual configuration.

## What is not here yet

* **Kubernetes.** Named as a target the design must not need a rewrite for, not as a thing that runs.
