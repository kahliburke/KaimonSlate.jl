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
| A cell says | `#%% sweep cluster=hpc` | `#%% code region=gpu` |
| Runs as | scheduler jobs | a live Slate worker |
| Outlives the notebook | yes | no |
| Where the work goes | wherever the queue puts each job | one node, held for a walltime |
| Results | land in a store, read back on demand | ordinary values in the namespace |

Both are configured on the front page, under **🖧 Remotes** — a cluster describes a *machine*, and a
notebook that names one carries only the name.

## Defining a compute target

**🖧 Remotes → Compute targets** on the front page. A target is what a `#%% sweep cluster=<name>`
cell submits to:

| Field | What it is |
| --- | --- |
| **Name** | what a cell writes as `cluster=…`. A plain identifier — it goes in a cell header. |
| **Kind** | `slurm`, `pbs`, or `local` to run the same units as processes here with no scheduler. |
| **Login host** | the ssh host you submit from. Slate asks it what scheduler it has and offers the queues it reports. |
| **Store** | a path **on the cluster**. Put it on scratch: `$HOME` is a few tens of GB and is not built for parallel writes. |
| **Partition / walltime / cpus / mem** | what each job asks for. A cell may override any of them. |
| **Project** | the folder with the `Project.toml` the units run in. |
| **Chunk** | how many sweep units ride one scheduler job. |
| **Prologue** | shell run before every job — `module load julia`, usually. |

The **name is the contract, not the address**. A notebook says `cluster=hpc`, and each machine that
opens it resolves that against its own registry — which is what lets the same notebook run against a
laptop's test cluster and a site's real one with nothing edited in a cell. It is also why a target
you have not defined produces an error naming the ones you have, rather than a silent local run.

## Sweeping

```julia
#%% sweep id=scan cluster=hpc walltime=04:00:00
results = @sweep paramgrid(; n = 1:64, seed = 1:20) do p
    simulate(p.n, p.seed)
end
```

The cell is a **reconciler**, not a submit button. Running it again submits only what is missing: it
never recomputes a unit that has already landed. That is what makes the header attributes safe to
edit — resources are not part of the sweep's identity, so raising a walltime *resumes* the sweep
rather than discarding the units that already finished.

Because it reconciles, the honest thing to do with a sweep cell is run it repeatedly. It tells you
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
#%% sweep id=runs cluster=hpc data=auto
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
| **cpus / mem / gpus / account** | the rest of the request. |

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

## Waiting for a node

A region on a scheduler does not have an address until the scheduler grants one, and on a busy cluster
that wait is minutes. Running a region cell asks for a node and says so; the cell then **runs itself**
when the node lands, along with anything downstream of it. The region's pill reports `queued` for the
duration, and the bring-up narrates into the banner — a cold region installs the notebook's whole
environment on the far side, which is real work that should not look like nothing happening.

The allocation is found by job name, so reopening the notebook attaches to the node it was already
using instead of queueing for a second one.

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
