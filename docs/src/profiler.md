# Profiling a Cell

Every code cell can be profiled where it runs, on this machine or on a region's worker. Click **🔥**
in the cell's header, or pick **Profile the selected cell** in the command palette. The profiler
opens as a dock over the notebook, titled with the cell, and shows the last profile of that cell if
there is one.

**▶ Run and profile** runs the cell for real with the profiler armed, so its output and bindings
are the ones that run produced.

![The profile dock: the facts strip over a flame graph keyed by the cell's lines, with the code pane and the hot lines table](./assets/profiler-flame.png)

## What to measure

The **▾** beside the run button sets what the next run records. Its choices are kept per browser.

| Setting | Choices | What it changes |
| --- | --- | --- |
| measure | CPU, wall time, allocations, GPU | What a sample means. See below. |
| sample every | 0.1 ms to 10 ms (default 1 ms) | How often the profiler stops the threads to look. |
| buffer | 8 MB to 512 MB (default 32 MB) | How many samples fit. A full buffer is reported in the facts strip. |
| record | 0.1%, 1%, 10%, all | Allocations only: the share of allocations sampled. |
| trace | on (default) or off | Also record what compiled during the run and every runtime dispatch. |

- **CPU** samples where each thread is running, and leaves out time a thread spent idle.
- **Wall time** samples every thread whether it is running or waiting, so a cell that is slow
  because it waits (on I/O, a lock, a remote call) shows where.
- **Allocations** weights the graph by bytes allocated rather than time, and adds a table of what
  was allocated by type. It has no timeline.
- **GPU** samples the CPU as in CPU mode and records the GPU's kernels, memory copies and driver
  calls through CUPTI. It needs CUDA.jl in the notebook's environment and an NVIDIA GPU.

Only one profile runs at a time in a worker. A run that starts while another is profiling runs
unprofiled and says so.

## Reading the profile

The **facts strip** under the header gives the run's samples, threads, time spent waiting, how
much of it was compiling and garbage collection, and, when the cell has run without the profiler
since its code last changed, how long it took then. Fewer than 100 samples is flagged: the ranking
of lines is noise at that size.

Four tabs show the samples:

- **Flame graph**: an icicle keyed by source line, with the cell's own lines on the top row.
  Marks on a bar say where time went to runtime dispatch (⤳), compiling (⚙) or garbage collection
  (♻). Scroll to zoom, drag to pan, shift-drag to zoom to a span. **+**, **−** and **Fit** in the
  bar above do the same.
- **Timeline**: a lane per thread over the run. In GPU mode there are lanes for the CUDA calls and
  for each GPU stream, so idle gaps between kernels show.
- **Functions**: every function by self and total time, with what called it and what it calls.
- **Details**: the static check (below), what was allocated by type, the GPU's busy time and
  longest idle gaps, time on the GPU by line, what compiled during the run, and where dispatch
  happened at run time.

![The Timeline tab on a threaded cell: a lane per thread over the run, each finishing at a different time, with the code pane beside it and the hot lines below](./assets/profiler-timeline.png)

Beside the graph is the **code pane**: the source of the selected frame with each line tinted by
its total share, and the share in the margin. Source comes from the machine the cell ran on, so a
region cell's package code is the code that ran. Under the graph, the **hot lines** table lists the
lines with the most time of their own.

**fold libraries** (on by default) folds Base, the standard libraries and registered packages (not
the ones you develop from a local checkout) into one bar per package, and charges their time to the line of your code that called them. That is
the line a fix would change. Click a folded bar to open it. **%** and **time** switch the units;
**/** searches function and file names.

## Comparing runs

The last 30 profiles of each cell are kept. The first menu in the header opens an earlier one.

A new profile is compared with the one shown before it, when that one measured the same thing on
the same machine. The graph's bars turn red where a line's share grew and blue where it shrank,
and the hot lines table gains a **before** column. **compare with…** picks any kept profile to
compare against instead, and stays until it is changed.

![A profile compared with the run before it: grown bars red, shrunk bars blue, and the before column in the hot lines table](./assets/profiler-compare.png)

## Compile and the static check

**Compile** compiles the cell's code at the types it currently has, without running it, so the
next run measures the work rather than the compiler.

If the notebook's environment has JET, Compile also checks the cell's code statically. **＋ JET**
in the header offers to add it. The findings are listed under **Details** and marked with a wavy
underline in the code pane; hover one for what it means and the usual fix:

- **dispatch**: the method is chosen while the code runs rather than when it compiles.
- **boxed**: a closure reassigns a variable it captured, so the variable lives in an untyped box.
- **unoptimized**: the compiler gave up optimizing the call.

## Exporting

**export** writes the profile as a [speedscope](https://www.speedscope.app) file or a pprof `.pb`,
for the tools that read those.

## Cells on a region

A cell tagged for a region is profiled on that region's worker, and the dock says where. If the
region has no worker yet, the dock waits, and the cell is profiled when it next runs there.

## The agent

The agent can profile too, with the `prof_run`, `prof_summary`, `prof_tree`, `prof_source`,
`prof_check` and `prof_eval` tools. `prof_summary` describes the run in text: the run's figures,
the comparison with the previous profile, and the lines by their own time. Its percentages leave
out time spent waiting, and it says so.
