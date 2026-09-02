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
| **Kind** | `slurm`, or `local` to run the same units as processes here with no scheduler. |
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

The first cell tagged for the region asks the scheduler and waits for a node. A busy queue is
reported rather than hidden — the request stands, and running the cell again attaches to it. It is
found by job name, so reopening the notebook lands on the node you were already using instead of
queueing for a second one.

A compute node is normally not reachable from your laptop at all, only through the login node. Slate
registers that route the moment it learns which node it got, so everything after — the worker, the
tunnel, file sync — goes the two hops without being told.

**Giving it back.** The Remotes modal shows what a region is holding (node, job id, time left) with a
**Release** button. A region that drains to no workers releases on its own, and deleting a region
always does. The commonest way to waste a cluster is an allocation nobody remembers.

## Authenticating once

Plenty of production clusters refuse public keys. You get a password and a second factor, and every
ssh call Slate makes uses `BatchMode=yes` — which disables interactive authentication precisely so a
hub never hangs on a prompt nobody can see.

The way through is that **only one connection has to be interactive**. Slate opens a multiplexed
master with you: a dialog appears in the page for each thing ssh asks, showing ssh's own wording, so
the same path handles a password, a numeric code, a Duo menu, or a push that takes a while. Nothing
about it is scripted, and Slate never sees your second factor before you type it.

Everything after rides that master — sweeps, regions, rsync, byte-range reads — so a cluster that
costs a 2FA prompt costs exactly one, not one per subsystem. The master persists across idleness
(`KAIMONSLATE_SSH_PERSIST`, 8h by default), so a notebook left alone over lunch does not cost another
prompt.

## Reading results back

Slate does not assume it can see the cluster's filesystem — the normal deployment is a laptop driving
a cluster it has no mount on. So:

* **Metadata is mirrored.** Manifests and status are rsynced into a local shadow, so asking what a
  sweep is doing costs the new manifests and nothing else.
* **Data stays put.** A unit's results are read by byte range over the same multiplexed connection.
  With `data=lazy` a slice costs the bytes it names rather than the whole result.

Which is why the last step is unremarkable: a batch result and a value from an interactive worker are
both just values in the notebook's namespace, and combining them is ordinary Julia.

## What is not here yet

* **PBS.** Detection works and a region can be configured for it, but neither the batch launcher nor
  the allocation commands are implemented — Slate says so rather than issuing SLURM commands to a
  scheduler that has never heard of them.
* **Kubernetes.** Named as a target the design must not need a rewrite for, not as a thing that runs.
