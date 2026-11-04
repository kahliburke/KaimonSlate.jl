# Workers and Telemetry

Each notebook runs in a worker: a Julia process of its own on this machine, plus one on each
region its cells use. The **worker pill** in the top bar shows the notebook's workers and their
state. Click it to open the **worker dock**, a drawer along the bottom of the page.

![The worker dock: the notebook's workers on the left, the selected worker's controls and details, and its telemetry](./assets/worker-dock.png)

## The worker dock

The dock has three columns: every worker of the notebook, the selected worker's controls and
details, and its **Telemetry** or **Log**. Drag the dock's top edge to resize it; **✕** closes it.

The controls depend on the worker:

| Control | Shown for | What it does |
| --- | --- | --- |
| ⟲ Restart | every worker | Restarts the process. A region keeps its allocation. |
| ■ Shut down | a running worker | Stops it. On a remote host the process is removed. |
| ⏏ Release node | a scheduler region holding a node | Gives the node back to the scheduler. |
| ⏏ Cancel request | a scheduler region waiting in the queue | Withdraws the request. |
| ▶ Start | a region with no worker | Starts one now rather than at the next run. |
| run location | the notebook's main worker | Where the notebook runs; **change ▾** picks another. |

Under the controls are the worker's details: host and how it is reached, its ports and process,
whether it was started fresh or adopted warm, its data and environment directories, and, on a
scheduler region, the walltime left, how long it has been idle and when it will be released, and
how far its clock is from the hub's.

**Recent messages** lists the worker's six newest log records. Click one to open the Log tab at
that line.

While a worker starts, the pill shows the current step, and the dock shows the package
precompile's progress and its build log.

## Log

The **Log** tab reads the worker's own log file, page by page, however large it is. The level chips
filter by severity, and the search covers the whole file, not only what is on screen.
**☰ → 🪵 Worker log** opens the dock at this tab. Before a region's worker has written a log, the
tab shows the trace of acquiring its node.

## Telemetry

The **Telemetry** tab charts the worker's resource use. **1m**, **5m**, **15m** and **All** set the
range.

- **Tiles** for CPU, memory, each GPU, garbage collection, compilation, threads, open files and
  free disk.
- **Timeline**: every cell run as a bar, with a lane for garbage collections. Click a run to go to
  its cell; a profiled run opens its profile. **Minor GC** and **Full GC** run a collection now.
- **CPU and memory** over time. On a scheduler node the CPU chart is scaled to the job's
  allowance, and memory is drawn against the job's limit.
- **GPU** utilisation and memory, all GPUs together or each on its own.
- **I/O, pressure and the Julia runtime**: disk and network rates, how long work waited for CPU,
  memory or I/O, and the heap, allocation rate and memo store.

GPU figures come from NVML, so they need an NVIDIA GPU. The host and job figures (per-core use,
I/O, pressure, the job's limits) are read from Linux and are left out on other systems.

The telemetry of each notebook is also written to disk, one file per day under the cache home's
`telemetry` folder, and kept for 14 days. `telemetry_log` (on by default) and
`telemetry_keep_days` in `slate.json` change that; see [Running the Hub](hub.md).

## Across notebooks

The hub's front page has a **Worker activity** panel listing every worker the hub runs, for every
notebook. Clicking a row opens the same telemetry view.

## Dedicated threads

A worker keeps two small pools of threads of its own for its machinery: one answers the hub
(status, cancel, telemetry, transfers) and one serves the page (live re-renders, table pages,
completions). A cell that keeps every `:default` thread busy then cannot stall either. They come
from the DedicatedThreads package, which the hub installs in the background into an environment
of its own; until it is ready, workers use Julia's own pools. `worker_pools_source` in
`slate.json` points it at a local checkout or a git URL, or turns it `off`.
