# Clusters: batch sweeps and interactive nodes

Slate uses a cluster in two ways.

A **batch sweep** submits many parameter combinations as scheduler jobs. The work outlives the
notebook: you can close the laptop and come back to results.

An **interactive region** holds one compute node for a walltime and runs a live Slate worker on it.
You run cells there, change them, and run them again. It runs on a compute node, not on the shared
login node.

Both use one authenticated connection, one store, and one set of results:

| | Batch sweep | Interactive region |
| --- | --- | --- |
| A cell says | `#%% job cluster=hpc` | `#%% code region=gpu` |
| Runs as | scheduler jobs | a live Slate worker |
| Outlives the notebook | yes | no |
| Where the work goes | wherever the queue puts each job | one node, held for a walltime |
| Results | land in a store, read back on demand | ordinary values in the namespace |

Both are configured on the front page, under **🖧 Remotes**. A machine is defined there once, and a
notebook that uses it carries only its name.

## Defining a machine

**🖧 Remotes → Machines** on the front page. A machine is what a `#%% job cluster=<name>` cell
submits to, and what a region runs its workers on when it names one. The list shows each machine as
⎈ with its kind and host; **＋ New machine** opens an empty form.

![The Machines tab: a SLURM machine with its login host, the scheduler it reports, the partition menu, the per-job resources, its readiness and its scheduler use](./assets/machines.png)

| Field | What it is |
| --- | --- |
| **Name** | What a cell writes as `cluster=…`. A plain identifier, since it goes in a cell header. |
| **Kind** | What schedules the work: `slurm`, `pbs`, or **no scheduler** (`exec`), where Slate starts the processes itself. |
| **Login host** | `slurm`/`pbs`: the ssh host you submit from. Slate asks it which schedulers and queues it has, and says when the kind you chose is not the one it found. |
| **Host** | `exec`: where the processes run. Blank runs on this machine. |
| **Store** | A path **on the machine the work runs on** (this one, if Host is blank). On a cluster put it on scratch: `$HOME` is small and is not built for parallel writes. |
| **Store access** | Who may read the store. See [Who can read a sweep](#Who-can-read-a-sweep). |
| **Partition** | The queues the host reported, as a menu. A queue that is down is shown and cannot be picked. |
| **Per job** | **walltime**, **cpus** and **memory** for each job. A cell may override any of them. |
| **Options** | `slurm`/`pbs`: further scheduler options, as rows of name and value. See [SLURM and PBS](#SLURM-and-PBS). |
| **Project** | The local project the units run in. Blank is the notebook's own, which is almost always right: its exact Manifest is what the tasks get. |
| **Depot** | Where Julia keeps packages and compiled code on that machine. Blank is automatic: the site's scratch filesystem when Prepare finds one, else `~/.julia`. Shown when a host is set. |
| **At once** | `exec` only: how many tasks run in parallel. Blank follows the machine default (see [No scheduler](#No-scheduler)). |

**More settings** folds away the fields a site sets once. Its label counts how many of them are set.

| Field | What it is |
| --- | --- |
| **Chunk** | How many sweep units ride one scheduler job. Blank is automatic. |
| **Account** | `slurm`/`pbs`: the charge code, if the site bills one. |
| **Prologue** | `slurm`/`pbs`: shell run before every Julia on the machine, a region's worker as much as a job. |
| **Test QoS** | `slurm`/`pbs`: the queue for the test task that runs before a sweep's first submission (see [Preparing](#Preparing-a-machine-or-a-region)). `debug` on most sites. |
| **Compile** | `slurm`/`pbs`: **on the granted node** (the default) or **on the login node**, for sites that ask for compiles on login nodes. Compiled code is reused on a node of the same CPU architecture; a node of another architecture compiles for itself. |
| **Task script** | `slurm`/`pbs`: the path of the task runner on the cluster. Blank uses the one Slate ships. |
| **Julia** | A julia binary to use. Blank installs juliaup at the hub's Julia version, so results and environments carry across. Shown when a host is set. |
| **Transfer host** | A data transfer node for bulk reads of a region's files and adopted datasets. Blank uses the login host. Shown when a host is set. |
| **Note** | Free text, shown when you point at the machine in the list. |

**Save** (or **Create**) writes the definition. Below it, a machine with a host has a
**Readiness** row (see [The Readiness row](#The-Readiness-row-and-the-prepare-dialog)), and a
`slurm`/`pbs` machine has a **Scheduler use** row.

### Scheduler use

Sites limit how often one account may call the scheduler. The hub counts every scheduler command it
sends a host (`squeue`, `sbatch`, `qstat`, and the rest), by command and by the Slate function that
sent it. Nothing here asks the cluster.

The **Scheduler use** row reads `N in the last minute · N in 10 min · N in the hour · budget B/min`,
refreshed every 15 seconds. It turns amber when the last minute went over the budget.

![The scheduler-use dashboard: counts against the budget, commands per minute over a day, and the commands by the function that sent them](./assets/sched-use.png)

**Details** opens a dashboard for the host:

| Part | What it shows |
| --- | --- |
| **1h / 6h / 24h / 7d** | the window. It opens on 24h. |
| Tiles | last minute, last 10 min, the whole window with its per-minute average, the busiest minute with how many minutes went over budget, and the count since the hub started |
| **Commands per minute** | one bar per minute, with the budget as a dashed line. Bars over it are amber. |
| **By command and caller** | each command, the function that sent it, its count, and its share of the window |

The budget is `KAIMONSLATE_SCHED_BUDGET` commands per minute, 2 by default. When a host's last
minute goes over it, the hub logs a warning with the breakdown.

### The shell every Julia starts in

Everything a machine says about running Julia is applied in one place, to every Julia started there:
a region's worker, the build of an environment, Prepare's checks and each task of a sweep. Julia goes
on the `PATH`, the depot becomes the first entry of `JULIA_DEPOT_PATH`, the module fix Prepare found
runs (for example, unloading a CUDA toolkit module that puts the system's CUDA libraries ahead of
CUDA.jl's), then your prologue.

The depot location affects load times. On a shared home filesystem every package load checks its
compiled cache against the source files one metadata lookup at a time, which can double the time
`using CUDA` takes compared with scratch, warm or not.

### Who can read a sweep

A store holds the results, the job output, and the source of the body that produced them, including
whatever the closure captured on its way to the cluster. It lives on scratch, outside whatever
protection your home directory has, on a machine shared with other accounts.

**Store access** sets the store's directory mode, and every process that writes into it runs under a
matching umask:

| Choice | Mode |
| --- | --- |
| **Only me** | `0700`, the default |
| **My group can read** | `0750`, for a site that puts collaborators in a project group |
| **Site default** | the site's own umask (stored as `umask`), which on most clusters is world-readable |

A definition that names some other octal mode keeps it, shown in the menu as `mode NNNN`. For `exec`,
the row appears when a host is set.

This is about the filesystem. Who can connect to a worker is a separate question, answered by CURVE
and an allow-list holding only your hub's key; see [Remotes](remotes.md).

### No scheduler

`exec` means no scheduler. **Kind** says what schedules the work and **Host** says where it runs, so
the two are independent: a blank host runs here, and a host with no queueing system on it (a lab
workstation, a cloud VM) is a target like any other. Slate starts the processes over that machine's
session, watches them by pid, and kills them on cancel. The store, the environment and the task
runner are provisioned as they are for a cluster.

(`local` is the older spelling of `exec` with no host. Definitions using it keep working.)

An `exec` target has no scheduler limiting how much of the machine it takes, so Slate limits it. Each
task is a whole Julia loading the project, so memory rather than cores is the constraint, and the
default is well under the core count. A workstation with room to spare can raise it once for every
local target on this machine:

```julia
KaimonSlate.set_local_procs!(8)     # 0 restores the machine default
```

A target's own **At once** overrides it.

The **name** is what a notebook refers to, not an address. A notebook says `cluster=hpc`, and each
machine that opens it resolves that against its own registry. The same notebook can run against a
laptop's test cluster and a site's real one with nothing edited in a cell. A target you have not
defined produces an error naming the ones you have, rather than a silent local run.

## Machines and regions

Machines and [regions](regions.md) are defined separately, and each can stand in for the other:

* **Every machine with a host is also a region of the same name**, unless a region already has that
  name. Under the host in **🖧 Remotes → Regions** it is listed as 🖥 with the label `machine`. It
  takes its shape (partition, walltime, memory, GPUs, account, options) from the machine, and its
  interactive settings (transport, idle release, liveness, data root, sysimage) start at their
  defaults. Editing it saves only what you changed, and a **reset** button appears that drops those
  changes and takes the machine's settings again. Its workers and node stay.
* **A region that names a machine** (its **Machine** row) gets the machine's scheduler, account,
  Julia, depot and prologue, and fills any of partition, walltime, memory, GPUs and account it leaves
  blank from the machine's. Its options go over the machine's. The list shows it as `on <machine>`.
* **A region on a machine is also a `cluster=` target** of the same name: the machine's entry with the
  region's shape over it. `cluster=gpu_shared` sends a sweep to the nodes `region=gpu_shared` sends a
  worker to.
* **A job cell with `region=<name>` and no `cluster=`** runs its units on the node that region holds.
  The hub starts a task worker there, in the notebook's environment, and hands it the queued chunks
  one after another, so loading and compilation are paid once. If no node is held, the sweep asks for
  one as a region cell does, and queued work counts as use for the region's idle release. A task
  worker stops after two minutes with nothing queued. One that fails is replaced after a wait that
  doubles each time; after three failures in a row the attempt goes back to the sweep's own budget.
  The store is the machine's store under `regions/<name>`, else `sweeps` under the region's data
  root; a region with neither cannot run a sweep. These sweeps do not run the environment test
  described under [Preparing](#Preparing-a-machine-or-a-region).

## Sweeping

```julia
#%% job id=scan cluster=hpc walltime=04:00:00
results = @sweep paramgrid(; n = 1:64, seed = 1:20) do p
    simulate(p.n, p.seed)
end
```

The `@sweep` call does not say where the work runs. That is `cluster=hpc` on the header, so the cell
names a target, and the ⚙ changes it without touching Julia. Make the cell a **Job** cell (the kind
picker on the cell, or `#%% job`). `@sweep` runs in an ordinary code cell too, but there the target
has to be written into the body, `walltime=` and `chunk=` have nowhere to live, and there is no ⚙.
Passing a target positionally is for a standalone `.jl` outside Slate, where there is no header to
read.

The cell is a **reconciler**. Running it again submits only what is missing; it never recomputes a
unit that has already landed. Resources are not part of the sweep's identity, so raising a walltime
*resumes* the sweep and keeps the units that already finished.

The body travels as **source**, because a compute node cannot revive a function value. Data in
notebook variables is captured and shipped. `using` is written in the body and lifted out to run
once per job. A function, macro or struct the notebook defines is traced to the cell that defined it
and travels too, transitively, so a helper that calls a helper works. Editing one **re-keys the
sweep**, as editing the body does: it is part of what computed the results, so it is part of their
identity.

### `@sweep` options

Written after the grid, as `key = value`. An unknown option is an error.

| Option | What it does |
| --- | --- |
| `setup = begin … end` | Definitions the body needs, written out. For a helper with no cell behind it. Part of the sweep's key. |
| `script = "model.jl"` | A file of definitions, resolved next to the notebook like `@asset`. Its source travels with the sweep and is part of its key, so editing the file re-keys the sweep. |
| `summary = expr` | Runs on the compute node over each unit's value and records the result for the chart. `summary = sum(abs2, v)` is read as `v -> sum(abs2, v)`. Use it when a unit's value is too large to record inline. |
| `plot = f` | Your own chart: `f(rows)` returns an `echart(…)` or an option `Dict`, called over every unit in grid order, landed or not. `plot = false` shows no chart. |
| `probe = false` | Sends the whole grid in the first submission. See below. |
| `cap = n` | Refuses a submission of more than `n` chunks. |
| `lazy = true` | Stores results addressably, as `data=auto` on the header does. |
| `resources = (; …)` | Resource overrides in the source. The cell header wins over them. |
| `submit = true` | Starts the sweep when the cell runs, without a card. For a script outside Slate. |

**The probe wave.** With nothing landed yet there is no evidence the body works. So a started sweep
sends one chunk first and waits. Once a unit from it has landed, the rest of the grid goes out. If
the probe fails, the sweep stops there and has cost one short job. `probe = false` skips this, which
suits re-running a body you have already watched work.

### Submitting

Running the cell never spends anything. It writes the sweep's descriptors, computes the plan, and
the card reads **ready**. **Submit** starts it.

A sweep on a machine its notebook's environment has never run on is not submitted at once. The card
reads **held** and says it is testing its environment on the nodes first. The hub starts that test
itself (see [Preparing](#Preparing-a-machine-or-a-region)) and submits once it passes. While it runs,
a line on the card names the step the test is on. Click the line to open the prepare dialog. The hub
starts the test once per machine and project while it runs. If the test fails, the line
says where, and you start it again from the dialog with **Prepare again**.

![A sweep card held while its environment is tested on the nodes, with the step the test is on below the counts](./assets/sweep-testing.png)

From then on the hub's supervisor keeps the sweep going: it submits the next wave, and resubmits
what is missing, until the sweep finishes or you cancel it. That happens with or without the
notebook open. A cluster nobody is signed in to waits until someone signs in.

### The sweep card

![A sweep card while its units land: the counts, the rate and the time left, the chart filling in, and the unit grid](./assets/sweep-running.png)

The card shows only the buttons that apply to the sweep's state:

| Button | When | What it does |
| --- | --- | --- |
| **Submit N units** | ready | starts the sweep |
| **Cancel** | running or queued | cancels its jobs and stops it |
| **Resume** | cancelled | starts it again from where it stopped |
| **Retry N failed** | units failed | forgets the failed results and submits them again |
| **Retry N units** | units never landed within their attempts | as above, and gives those units their attempts back |
| **Logs** | a job has been submitted | opens the log viewer, described under Reading a job's output below |
| **Reset** | anything to throw away | cancels live jobs and discards the results and submission history, leaving the sweep ready. Asks first. |

While it runs, the card shows the units done, failed and remaining, how many jobs the scheduler has
running and queued, the rate, and the time left with the clock time it should finish. A line says
when nothing has finished for a while.

**The unit grid** has one tile per unit, or per several units once the grid has more than 600.
Pointing at a tile shows its parameters, how long it took, the node it ran on, when it landed, and
the error of a failed unit (up to three for a tile that holds several). Clicking a tile opens the log
of the chunk that ran it.

![The same card once the sweep is complete](./assets/sweep-card.png)

**The chart** plots each unit's recorded value (or its `summary`) as units land. When the value has
several numeric fields, a menu above the chart picks the one it shows.

### The ⚙ job-cell panel

The ⚙ on a job cell opens its settings beside its live state. Settings are on the left; drag the
divider to resize.

![The job cell's ⚙ panel: the cluster, the cell's scheduler options, storage and units per job on the left, and the cluster's live jobs, units, store and sweeps on the right](./assets/job-panel.png)

| Setting | What it does |
| --- | --- |
| **Cluster** | the machine the cell runs on, with a one-line summary of it |
| **Scheduler options** | this cell's overrides, as rows of name and value. The name box suggests catalogued options as you type. An unknown name, or one the cluster's scheduler cannot express, is marked amber and still sent. |
| **storage** | `data=`: **auto** (the default) stores a result addressably when its shape allows, **arrow** chunks row output even when it is small, **whole** stores each value as one blob, handed back intact |
| **units per job** | `chunk=` |

Blank fields inherit from the cluster. **Apply & reconcile** saves and re-runs the cell, which
submits only what is missing. `cluster=`, `data=` and `chunk=` go on the cell header. The scheduler
options are saved in the notebook's `Slate.job` footer, because a header value cannot hold characters
such as `@` in `--licenses=ansys@srv` or a space.

The **Live** column reads the cluster's store. It refreshes every few seconds while a sweep of this
notebook is running, and every 20 seconds otherwise:

| Group | Figures |
| --- | --- |
| compute | **jobs** running and queued, with how many were submitted; **units** done of total; **failed**, with how many are outstanding; **rate** and its eta; **nodes** in use |
| data | **output** the sweeps claim; **on disk**, what the store weighs, with any unreferenced bytes; **read**, how much has come back; **throughput** of the reads |

Below them are the store's path on the cluster and its local mirror, then a table of this notebook's
sweeps in the store: id, cell, state, units, started, ended, took, stored and read. Click a heading
to sort. **✕** on a row deletes that run's results and frees their space, after asking. It is not
offered while the run still has units in flight.

### The sweep pill

While a notebook has sweep cards, a pill in the top bar sums them up:

* while any sweep runs: `done/total units · N%`, counted over the running sweeps only, then the
  number of sweeps, how many are testing, and how many stopped;
* otherwise `N sweeps stopped`, `N sweeps ready` or `N sweeps done`;
* then failed units, the output the sweeps hold, and `↓` how much of it has been read back.

Click it for one row per sweep: its cell, state, units, failures, rate, finish time, output and
share read, with a progress bar. The foot totals output and read. Click a row to scroll to its cell.

### Output too large to bring back

`data=auto` on the cell header stores a unit's result **addressably**: chunked and indexed where it
ran. The notebook holds an index of kilobytes, and a slice moves only the bytes it names.

For output that never becomes a Julia value (a solver writing HDF5 or NetCDF from inside itself),
return `adopt(path)` instead. The file is read on the compute node that wrote it and re-emitted in
the same addressable form, so nothing extra crosses the wire:

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
on the node as they do in the notebook: the per-region scratch, beside the job.

`adopt(p1, p2, …)` (or `adopt(paths)`) adopts several files as one dataset. A variable name that
appears in more than one of them is an error.

`adopt` works in an ordinary cell too. On a region, the file is stored in a dataset store under the
region's `datadir()`, and the cell's value is the dataset. A relative path is read as under
`datadir()`, as `@sfile` builds it. Read from the notebook, that value is the index, and each slice
is read from the region over ssh:

```julia
#%% code id=frames region=gpu
frames = adopt(@sfile("run.nc"))      # n(x, y, z, t), stored once on the region

#%% code id=first_half
n = frames[:n]                        # the variable, still on the region
block = n[:, :, :, 1:200]             # one contiguous read of 200 frames
```

An unchanged file is not read again, so re-running the cell costs nothing.

A file adopted on a region can be opened from any notebook, with nothing running on the region:

```julia
Sweep.adopted("gpu", "run.nc")     # the dataset; the path is under the region's data root, or absolute
Sweep.adoptions("gpu")             # every file adopted there, newest first: (; file, rel, created, bytes, vars, dataset)
```

Both need the region to have a data root. Reads go through the machine's **Transfer host** when it
has one.

HDF5 (`.h5`, `.hdf5`, `.he5`) and NetCDF (`.nc`, `.nc4`, `.cdf`) are recognised when HDF5 or
NCDatasets is loaded in the environment that reads the file. Another format needs an adapter:

```julia
SlateTask.register_dataset_adapter!("myformat",
    path -> endswith(path, ".myf"),              # does this adapter handle the path?
    path -> (file_attrs, vars))                  # vars: each a (; name, dims, attrs, data)
```

A registered adapter takes precedence over the built-in ones.

## Working on a compute node

A region whose host is a cluster's login node does not run there. The login node is where you
**ask**; the node is what you are **given**, and which node is an output of the allocation. It does
not exist until the scheduler grants it.

So a cluster region stores what to ask for. The form in **🖧 Remotes → Regions** has these rows for it
(the rest of the form is described in [Regions](regions.md)):

![The region editor for a region on a cluster's login host: its machine, scheduler, partition, walltime and resources, the idle release, the scheduler options and startup command, the node it holds, and its readiness](./assets/region-cluster.png)

| Row | What it is |
| --- | --- |
| **Machine** | a machine defined on this host, or the first entry, which uses the host directly. Picking a machine sets the scheduler from its kind. See [Machines and regions](#Machines-and-regions). |
| **Scheduler** | the one to use, or `none` to run on the host itself. Slate detects what a host has and offers it. The choice stays yours: a site can have both toolsets installed with only one running the jobs, and a login node you are content to run a small worker on is a valid answer too. |
| **Partition** | picked from the queues the host reported, with down queues shown as down. Blank uses the machine's, else the site default. |
| **Walltime** | how long to hold the node. An allocation bills for the time it is **held**, not the time it is used. |
| **Request with** | SLURM only: **sbatch** or **salloc**. See below. |
| **Resources** | **cpus**, **memory**, **gpus** and **account**. Blank takes the machine's, else the site default. A blank memory sends no request, so the queue's own default applies. |
| **Release when idle** | **idle for**: give the node back after this long with no region cell running (`30m`, `1h`, `2d`; blank never). **warn before**: ask first, this long ahead. |
| **More settings** | **Options**, scheduler options as rows of name and value, with the machine's options shown as inherited (a row here overrides one); and **Before start**, shell run on the granted node before the worker starts. A failure there stops the worker. |
| **Allocation** | what the region holds now: `queued as job N` with **Cancel**, or the node, its time left and its job with **Release**. **↻** asks the scheduler again. |
| **Liveness** | how long a worker may go without answering before its connection is dropped, such as `3m`. Blank uses what Prepare measured. |

The warning must be shorter than the idle timeout, and the form refuses one that is not. When the
walltime is shorter than the idle timeout, the form saves and notes that the allocation ends before
the timeout can fire.

On SLURM, **Request with** decides how the node is asked for. **sbatch**, the default, submits a job
that holds the node. **salloc** asks for an interactive allocation, which a site's interactive QOS
requires: it refuses submitted jobs, and it usually starts far sooner than a shared or regular one. A
request through `salloc` waits on the login node it was made from until the node is granted, so it is
lost if that login node goes down while it waits.

`mem = 0` asks SLURM for all of a node's memory, and SLURM adds CPUs to cover memory, so on a shared
queue it turns a request for one GPU into a request for the whole node. When the scheduler holds more
CPUs for a job than the region asked for, the prepare step and the queued line say so.

**Warm workers are not offered on a scheduler region.** They keep a worker on the host between
notebooks to skip the boot, and a scheduler region has no such host: its node is an allocation, and
the next one may be a different machine. Keeping workers alive would also stop an idle node from
being released, so the region would hold and bill for one until its walltime expires.

The first cell tagged for the region asks the scheduler and waits for a node. A busy queue is
reported: the request stands, and running the cell again attaches to it. It is found by job name, so
reopening the notebook lands on the node you were already using instead of queueing for a second
one.

A cluster you cannot reach at all says so in those words. From here it looks the same as a slow
queue (no node either way), and only one of them is about the scheduler.

A compute node is normally not reachable from your laptop, only through the login node. Slate
registers that route as soon as it learns which node it got, so the worker, the tunnel and file sync
all go the two hops without being told.

**Giving it back.** The **Allocation** row shows what a region holds, with **Release**. A region that
drains to no workers releases on its own, and deleting a region always does. An allocation nobody
remembers keeps billing until its walltime.

### Allocation notices

A notebook using a region gets a popup when its node is about to go, or has gone:

| Notice | What it offers |
| --- | --- |
| **Still using `<region>`?** | the region has been idle for its idle timeout and releases at the end of a countdown. **Release now** gives it back at once; **Keep** keeps it. |
| **`<region>`: allocated time expiring** | a countdown to the end of the walltime, and a reminder to save results. **Dismiss**. |
| **`<region>`'s node was released** | the walltime ran out or the idle timeout fired. The hub keeps this notice until you dismiss it, so a release that happened while no page was open shows on the next load. |

The first two also show **Extend by** with an amount (`30m` by default) and **Extend**, when the
scheduler has accepted an extension for that job. Most sites refuse, and then the control is not
shown. Each notice shows the region, the node, the login host it is reached through, and the
walltime left.

![The notice before an idle node is released, with its countdown, Extend, Release now and Keep](./assets/alloc-notice.png)

## Authenticating once

Many production clusters refuse public keys. You get a password and a second factor, and that is the
only way in.

Slate speaks SSH itself rather than driving the `ssh` command, so the server's `keyboard-interactive`
prompts arrive as values it can hand to you: a dialog appears in the page for each thing the server
asks, in the server's own wording. The same path handles a password, a numeric code, a Duo menu, or a
push that takes a while. Nothing about it is scripted, and Slate never sees your second factor before
you type it.

**One session per host.** Sweeps, regions, provisioning, file transfer, byte-range reads and port
forwards are channels on that one connection, so a cluster that costs a 2FA prompt costs one prompt.
A compute node is reached *through* its login node for the same reason: a session to the node itself
would be a second authentication. Large reads are the exception, on hosts that take keys (see
[Reading results back](#Reading-results-back)).

The sessions live in the **hub**, not in a notebook's worker, so one sign-in covers every notebook on
the machine: its sweeps and its regions. A worker that needs a cluster asks the hub rather than
opening its own connection.

**Signing in only happens when you ask for it.** It starts from the padlock at the top of the page
(or ⌘K → *"Sign in to a host"*), or from `Sweep.connect!(host; interactive = true)` in a cell.
Opening a notebook, reconciling a sweep and polling a roster all run against a session that already
exists and say "not signed in" otherwise. So a dialog never appears because a background poll
reached the host first.

![The sign-in dialog asking for a one-time code, with the server's own prompt below the field](./assets/ssh-signin.png)

The panel lists **hosts**, not clusters, because wanting a password is a property of the host's sshd:
a cluster can take keys and a plain remote can demand 2FA. Each row shows what uses it (which
machines, which regions) and whether it is signed in. **Check** asks the host which authentication
methods it offers *without* authenticating, so it costs no failed login on a server that counts
those.

## Preparing a machine or a region

A region's first worker on a new machine meets everything about that machine at once: Julia to
install, the worker's own packages, modules the site loads by default, a filesystem slower than a
laptop's. **Prepare** does that work on its own, outside any notebook, and reports each step. It
comes in layers:

* **A machine** (its **Readiness** row under 🖧 Remotes → Machines, or
  `slate_machine(name=…, action="prepare")`): sign in, Julia, read the site, settle the depot. What it
  finds belongs to the host, so every region and sweep there uses it.
* **A region** (its **Readiness** row, or `slate_region_prepare(name)`): the machine's steps, then
  the node.
* **A sweep's environment**: the machine's steps, then the notebook's task environment is built on
  the machine and **one test task** goes through the scheduler. It asks for the sweep's node type for
  20 minutes on the machine's **Test QoS**, precompiles there, loads every package and checks CUDA.
  When a region on the same machine already holds a node of that kind, the test runs on that node
  instead of queueing. Until a test has passed, the sweep submits nothing: a broken environment costs
  one short job rather than every task of the array. The hub starts this test when you submit a sweep
  (see [Submitting](#Submitting)). `slate_machine(name=…, action="prepare_batch", project=…)` runs it
  from the agent.

`slate_machine` also takes `action="list"`, `"show"` (a machine with what preparing found and the
environments tested there), `"set"`, `"delete"` and `"status"` (a running prepare, or the last one).

A region's prepare does this:

* sign in to the host, install Julia at the hub's version, read the site (CPU, default modules, CUDA
  libraries on the library path, Julia version);
* **Depot**: settle the depot, creating it and checking it is writable. An automatic depot is
  resolved here once, and every Julia on the machine uses it from then on;
* build the worker runtime, and create the data root and check it is writable;
* on a scheduler region, download the notebook's packages on the login node, where it costs no
  allocation;
* when the machine's **Compile** is **on the login node**, a step **Compile `<project>` on `<login
  host>`** compiles them there. A node of the same CPU architecture then finds them current;
* on a scheduler region, the first time: get a node, read it the same way, check that it sees the
  login node's files, time loading the worker runtime and the region's preload environment there,
  check CUDA, and give the node back;
* on a region with **sysimage** on, build its workers' sysimage where they run (the node, on a
  scheduler region) and in the machine's shell, after the packages are precompiled. The step says
  whether the image was built, was already current, or was put off and why (too little free memory,
  another build running, no C compiler). `slate_region_prepare(name, sysimage="rebuild")` builds it
  again even when it is current.

### The Readiness row and the prepare dialog

A **Readiness** row sits below the form's **Save**, on a machine with a host and on a region. Its
status line is one of:

| Status | Meaning |
| --- | --- |
| `not prepared` | no prepare has finished |
| `✓ prepared · 3h ago` | the last prepare passed |
| `⚠ <reason>` | the site has changed since the prepare, and the reason says how |
| `preparing · <step>` | a prepare is running, on that step |

A region's row can also read `⚠ prepared with failures` or `⚠ prepared with warnings`.

**Prepare** (or **Prepare again**) starts one. **Details** appears once there is a prepare to show,
and opens the prepare dialog. Under the status, the row shows the Julia version and depot in use and
any site prologue Prepare found.

A summary line, `▸ Environments N ready · N changed · N failed`, opens a table of the project
environments tested on the machine's nodes, newest first:

| Column | What it shows |
| --- | --- |
| mark | ✓ ready, ⚠ the packages changed since the test, ✗ failed to load |
| **project** | the project tested |
| **node** | the kind of node (partition and constraint) |
| **by** | what tested it: a region, or a sweep's test task |
| **loads** | how long loading took |
| **CUDA** | whether CUDA was functional |
| **tested** | how long ago |

The **prepare dialog** shows one prepare. **Steps** on the left lists each step as it lands, or the
planned steps before the first run. On the right, **Activity** is the log of the run and **History**
lists every earlier run with how it ended; click one to read its steps and log. The buttons are
**Prepare** and **Later** before a first run, **Hide** while one runs, and **Prepare again** and
**Close** after.

![The prepare dialog during a run: the finished steps with what each found, the step running now, and the activity log](./assets/prepare-dialog.png)

### What a region's sysimage holds

The region decides what its image holds. The list starts as the preparing notebook's registered
packages and its project's, and you can add any registered package, choose a release for each (the
newest is marked), or add a package from a path on the machine. Slate's own worker packages are
always in it. A package the notebook has from a path, its project included, is never baked: it loads
on top of the image, so editing it takes effect as it would without one.

The list is edited in its own dialog, which opens before a prepare that a notebook starts on a region
with **sysimage** on. Its **Prepare** keeps the list and starts the prepare. A prepare started from
the Remotes panel uses the list as it stands.

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
when they differ the region is marked stale, and **Prepare again** brings it up to date.

A notebook's packages loading on a machine's nodes is recorded once, with the machine, for that kind
of node (its partition and constraint). A region's prepare and a sweep's test task both write it, and
the same record decides for both: a region on those nodes needs no prepare of its own for a project a
sweep has tested there, and a sweep goes out without a test once a region has loaded its project
there. Either one waits when the machine's site has changed since it was prepared, when the packages
have changed since they were tested, or when nothing has loaded them on that kind of node yet.

A region cell in that position waits and offers **Prepare**. Prepared from the notebook, the region
also installs and precompiles those packages where the workers run, then starts the notebook's own
worker and loads them in it. The node and that worker stay for the notebook, and the waiting cells
run on it when the prepare ends. While a region is being prepared, its cells wait for it rather than
start a worker of their own beside it.

## Waiting for a node

A region on a scheduler has no address until the scheduler grants one, and on a busy cluster that
wait is minutes. Running a region cell asks for a node and says so; the cell then **runs itself**
when the node lands, along with anything downstream of it. The region's pill reports `queued` for
the duration. Once the node is granted, the bring-up shows on the
[worker pill and in the worker dock](workers.md): a cold region installs the notebook's whole
environment on the far side, and the pill shows each step.

![A region cell waiting for its node, with the panel shown when pointing at its chip: what was asked for, how long it has waited, when it should start, and the cluster's free capacity](./assets/region-blocked.png)

The allocation is found by job name, so reopening the notebook attaches to the node it was already
using instead of queueing for a second one.

Opening a notebook never asks for a node. A node bills from the moment it is held, so the run that
opening starts leaves region cells reading **run to request a node** when nothing is held, and
running them asks. A node that is already held is used straight away.

A held node with nothing running on it still bills until its walltime. Set the region's **Release
when idle** (**idle for** `10m`, say) to give it back after that long without a region cell running,
and **warn before** to be asked first.

## Reading results back

Slate does not assume it can see the cluster's filesystem. The usual deployment is a laptop driving
a cluster it has no mount on. So:

* **Metadata is mirrored.** Manifests and status are copied into a local shadow in one round trip, so
  asking what a sweep is doing costs the new manifests and nothing else.
* **Data stays put.** A unit's results are read by byte range from the login host. With `data=auto` a
  slice costs the bytes it names rather than the whole result.
* **Large reads get their own connections.** A fetch of 8 MiB or more opens a fresh connection,
  signed in by key, and closes it afterwards; a large fetch is split across several of them (4 by
  default), each carrying part of the bytes. A long-lived session can carry bulk data far slower than
  a new connection on the same path. A host that needs a password or second factor keeps using its
  one session.

Reads of a region's files and of datasets adopted there go through the machine's **Transfer host**
when it names one, else the login host.

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

A batch result and a value from an interactive worker are both values in the notebook's namespace,
and combining them is ordinary Julia.

### Reading part of a large result

An array part (one variable of an adopted file, or one unit's array) is indexed by its dimensions.
`v[i, j, …]` reads that selection as the contiguous runs it covers. Bytes read from a remote store
are kept in this machine's blob cache, which holds any subset of a blob, so a later read fetches only
what it lacks.

```julia
v = frames[:n]
Sweep.query_cost(v, :, :, :, 1:200)    # bytes, missing (not cached), fetch (what reading would move)
Sweep.prefetch!(v, :, :, :, 1:200)     # bring the selection into the cache without reading it
Sweep.selection(v, :, :, :, 1:200)     # v[…], with progress and a stop
Sweep.coverage(v)                      # (; bytes, present, fraction) of the part in the cache
Sweep.coverage(v, 4)                   # which frames along dimension 4 are fully cached
Sweep.evict!(v)                        # drop the part, or `evict!(v, …)` a selection, from the cache
```

A read that is stopped keeps what had landed, so asking again fetches only the rest.

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

A record **declares** its level, and that is believed over its wording: an `@info` that mentions a
failure stays info, so filtering a log to `error` gives you what went wrong rather than every line
containing the word. Output that declares nothing (a bare `println`, a C library, the scheduler's
own messages) is classified by its wording instead.

Colour is on: the stream is a file, so nothing can detect a terminal, and the viewer renders what
the logger emits.

## Reading a job's output

The costliest failures leave **no manifest** (an OOM kill, a walltime cut, a prologue that failed),
so `results.errors` is empty and the only account of what happened is what the job printed.
**Logs** on a sweep card opens it, and so does clicking a tile in the unit grid.

![The job output viewer: the sweep's log files by job, task and node, and one file's records with level filters and search](./assets/sweep-logs.png)

The viewer holds a window onto a file rather than the whole file, so a job that printed a gigabyte
opens as fast as one that printed a line. The menu in its header switches to another sweep in the
notebook without closing it.

The file list on the left has these columns. Click a heading to sort; the box above filters by file
or node name.

| Column | What it shows |
| --- | --- |
| **job** | which submission, when the sweep has more than one |
| **#** | the array task within its submission |
| **size** | the file's size |
| **modified** | when it was last written |
| **node** | where it ran |
| **pid** | the process that ran it, when known |
| **status** | how its chunk ended |

Over the file:

| Control | What it does |
| --- | --- |
| **all / info / warn / error** | filters by level. The counts are over the **whole file**: "error 40" means the file holds forty, not forty of what is on screen. |
| Search box | searches the whole file, wherever it lives. **Aa** ignores case (on by default), **.\*** treats the text as a regular expression, and ▲ ▼ walk the matches. A match past the end of the window is found and jumped to without reading what precedes it. |
| **↓** / **↑** | newest first (the default) or oldest first. Use oldest first for a traceback, which is written downwards. |
| **⏸** | stops following the file; **▶** follows it again. A growing file is re-read every few seconds while you are at the end that grows. Scrolled away, a **new output** button appears rather than the text moving under you. |

The same files are reachable from Julia:

```julia
Sweep.log_files(results)                       # what there is
Sweep.log_search(results, path, "OOM")         # the whole file, wherever it lives
Sweep.log_slice(results, path; offset = -4096) # the last 4KB
Sweep.logs(results)                            # every job's tail, headed by job
```

## SLURM and PBS

A machine's **Kind** picks the scheduler. Sweeping, regions, provisioning, the store and the
notebook itself are the same either way. The settings do not map one to one:

* **PBS asks for per-node resources inside a chunk statement.** `cpus`, `mem`, `gpus`,
  `ntasks_per_node` and `nodelist` become `-l select=N:ncpus=…:mem=…:ngpus=…:mpiprocs=…:vnode=…`, and
  `nodes` is the chunk count. Sizes are rewritten to PBS's spelling (`16G` → `16gb`). `mem_per_cpu`
  is multiplied by `cpus` into the chunk's memory.
* **`select=` is the escape hatch.** Write the chunk statement yourself and it wins outright. That is
  how a site resource Slate has no name for (`scratch_local`, a node feature, a specific host) gets
  asked for.
* **Options rows.** On SLURM each row of a machine's or region's **Options** is a long option
  (`--name=value`, or `--name` for a row with no value). PBS has no long options: a one-letter name
  is its own `qsub` flag (`-q debug`, `-W group_list=x`), and any other name is a resource
  (`-l name=value`). A machine defined with older free-text `directives` keeps them: lines in
  `--key=value` form are read as options, and any other line (`-l place=scatter`) is sent as written.
* **A setting one scheduler cannot express is flagged, and still sent.** `constraint`, `gres`,
  `exclude`, `reservation` and `ntasks` have no standard PBS form, and `select` has no SLURM one. The
  option editors (a machine's and a region's **Options**, and the job cell's ⚙) mark them amber with
  a `no pbs equivalent` hint and leave them out of suggestions. They are sent anyway, since a PBS site
  can define a resource of any name. The hub logs a warning once that names the usual way to ask for
  the same thing, and the scheduler rejects the job if the site has no such resource. Pointing a
  cell at a cluster of the other kind relabels its options.
* **Anything Slate has never heard of still works.** On SLURM a setting becomes `--key=value` with
  `_` → `-`; on PBS it becomes `-l key=value` as written, because PBS resource names carry
  underscores.

Two differences are visible in use:

* **A PBS job's log appears when the job ends.** PBS spools stdout on the execution node and copies
  it back at exit, where SLURM writes it live. Per-unit progress comes from the store either way, so
  this only affects reading the raw log of something still running.
* **A compute node is reached by ssh from the login node.** SLURM has `srun --overlap`, which joins
  a running allocation without logging in again; PBS has nothing equivalent, so it uses the ssh hop
  PBS sites already rely on. The hub still authenticates once (that ssh is issued *on* the login
  node's session), but the site has to permit it, which is the usual configuration.
