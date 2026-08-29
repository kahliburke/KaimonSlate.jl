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

#%% md id=h_target
@md"""
## Where it runs

A **cluster** is defined once for this notebook and referenced by name from any number of sweep
cells. Open the ⚙ on a sweep cell to see it, change it, or point the cell somewhere else. Two are
defined here:

| | |
|---|---|
| `slurm` | the Docker SLURM harness in `dev/slurm-harness` — partition `compute`, 1 cpu, 512M, ≤ 10:00 |
| `here`  | no scheduler at all: the same cells, as local processes |

That is the only thing that changes between a laptop and a cluster. The sweep cells below name one
and are otherwise identical, and the definitions live in the notebook file — so they travel with
it, show up in a diff, and moving every sweep to another cluster is a single edit.

A cluster's `root` is the shared store as this notebook sees it; `root_remote` is the same
directory as a compute node sees it. The harness bind-mounts one directory into both.

The science itself lives in a **package** (`dev/sweepdemo`), not in the notebook, and a sweep body
is a one-line call into it. Nothing has to be serialized or shipped: the package is the cluster's
`project`, provisioned once into the environment each task runs in. That also keeps that
environment small — SweepDemo and its dependencies, and none of the plotting or display packages
this notebook uses, which a compute node has no use for.
"""

#%% code id=target
# Demo housekeeping, not part of running a sweep: the Docker harness needs the task runner on the
# filesystem its compute nodes share, and copying it here means a source edit lands without
# rebuilding the container. `paramgrid` is defined in Slate's own `src/`, so the checkout is one
# `methods` lookup away — no path hunting, no hardcoded directory.
#
# The file list comes from `SlateTask.PAYLOAD_FILES` rather than being written out here, so a runner
# that grows a dependency cannot be shipped without it.
SRC     = dirname(String(first(methods(paramgrid)).file))
HARNESS = joinpath(dirname(SRC), "dev", "slurm-harness")
for d in ("cas", "env", "src"); mkpath(joinpath(HARNESS, "scratch", d)); end
for f in Sweep.SlateTask.PAYLOAD_FILES
    cp(joinpath(SRC, f), joinpath(HARNESS, "scratch", "src", f); force = true)
end

# How long each unit takes, and how many there are. Both are CAPTURED by the sweep bodies below,
# so changing either one re-keys the sweep and starts a new one rather than mixing results across
# settings. Raise them to exercise what a genuinely long run does: queue waits, ETA accuracy,
# stall detection, walltime kills.
COST  = 1.0      # seconds per unit
NSCAN = 40       # units in the full sweep

(; COST, NSCAN, shipped = length(Sweep.SlateTask.PAYLOAD_FILES), harness = HARNESS)

#%% md id=h_pilot
@md"""
## Pilot first

Before spending an allocation, run a handful of points and look at the output. Because every unit
is keyed by content, **these results are kept**: the full sweep below reuses them rather than
recomputing, and it is the same code path because only the grid changed.
"""

#%% sweep id=pilot cluster=slurm
# The SAME body as the full sweep below, on four of its points. A unit is keyed by body + setup +
# captures + parameters, so these four results are literally four of the ones the full sweep needs
# — it will not recompute them. The bodies have to match as CODE for that to hold; comments and
# formatting are not part of the key.
#
# No target argument: the cell header names one of the notebook's clusters (⚙ above).
pilot = @sweep(paramgrid(x = range(0, 8; length = NSCAN)[1:4]);
               setup = "using SweepDemo") do p
    3.85 < p.x < 3.95 && error("rigged failure near x = 3.9")
    SweepDemo.work((; x = p.x, ms = round(Int, COST * 1000)))
end

#%% md id=h_sweep
@md"""
## The full sweep

Forty units on the cluster, with a plot that fills as they land. Watch it without touching
anything: the card polls its own channel, that poll *reconciles*, so the probe wave completes and
the rest goes out on its own. The topbar pill carries the same summary when the card is scrolled
away.

Re-run this cell to refresh. It reconciles against the store and the scheduler and submits only
what is missing — once everything has landed it returns immediately having submitted nothing,
which is what makes reopening this notebook safe.

One parameter is rigged to throw, so the failure path is visible rather than theoretical.
"""

#%% sweep id=scan cluster=slurm
scan = @sweep(paramgrid(x = range(0, 8; length = NSCAN));
              # One number per unit, recorded in the manifest. The card reads summaries, never
              # results, so watching this costs the same whatever a unit returns.
              summary = v -> v.y,
              # The plot rides that same poll, so it fills as units land — no timer, no extra round
              # trip, and it cannot disagree with the counters beside it. It is handed EVERY unit in
              # grid order and plots `nothing` for the ones that have not reported: the axis is
              # fixed from the first frame and the line breaks at the real gaps, so a chunk landing
              # out of order adds a segment instead of rewriting the curve.
              plot = rows -> echart(Dict(
                  "backgroundColor" => "transparent",
                  "animation" => false,
                  "grid"    => Dict("left" => 45, "right" => 20, "top" => 30, "bottom" => 30),
                  "tooltip" => Dict("trigger" => "axis"),
                  "xAxis"   => Dict("type" => "value", "name" => "x", "min" => 0, "max" => 8),
                  "yAxis"   => Dict("type" => "value", "name" => "y", "min" => -1.1, "max" => 1.1),
                  "series"  => [Dict("type" => "line", "showSymbol" => true, "symbolSize" => 5,
                                     "connectNulls" => false,
                                     "data" => [[r.params.x, r.summary] for r in rows])]))) do p
    using SweepDemo
    # One rigged failure, chosen by index so it fires whatever NSCAN is.
    3.85 < p.x < 3.95 && error("rigged failure near x = 3.9")
    SweepDemo.work((; x = p.x, ms = round(Int, COST * 1000)))
end

#%% md id=h_downstream
@md"""
## Downstream of a sweep

The card above answers *how is it going* — progress, rate, ETA, which units failed and with what,
which node each one ran on (hover a tile). None of that needs a cell, and none of it goes stale.

What a cell is for is the **next step**: the sweep's result is an ordinary Julia value, and cells
that read it are ordinary cells. `r.results` gives only the units that landed, so this runs against
a half-finished sweep without having to decide what a missing point looks like — and when the sweep
finishes, the cells that read it recompute on their own.
"""

#%% code id=analysis
# The actual next step — and it reads only summaries, so it costs manifests rather than results.
# The generating function is exp(-0.15x)·cos(3x), so a fit through its local maxima should come
# back near 0.15.
landed = [(r.params.x, r.summary) for r in scan.results]
peaks  = [landed[i] for i in 2:length(landed)-1
          if landed[i][2] > landed[i-1][2] && landed[i][2] > landed[i+1][2] && landed[i][2] > 0]

decay = if length(peaks) >= 2
    xs, ls = [p[1] for p in peaks], [log(p[2]) for p in peaks]
    mx, ml = sum(xs) / length(xs), sum(ls) / length(ls)
    -sum((xs .- mx) .* (ls .- ml)) / sum((xs .- mx) .^ 2)   # least squares through log|y|
else
    NaN
end

(; fitted_on   = "$(length(peaks)) peaks in $(length(landed)) of $(length(scan)) units",
   decay_rate  = round(decay; digits = 3),
   held        = Sweep._bytes(scan.bytes),
   lost_params = [round(r.params.x; digits = 3) for r in scan.errors])

#%% md id=h_volume
@md"""
## When a unit returns a field, not a number

The sweep above measures one number per point, which is the easy case. Most real sweeps do not: a
unit produces an image, a spectrum, a lattice — something too big to read off a chart, and only
meaningful once every unit is in.

This one computes a **hydrogen orbital**, ψ₃₂₀, one horizontal plane at a time. Each unit returns a
128×128 field; the sweep assembles a volume; playing the planes back in order flies through it.
Watch the nodal cone open up as you leave `z = 0` — the surface where ψ changes sign, which is
exactly what makes the 3d<sub>z²</sub> orbital the shape everyone recognises.

Two views of the same run, and they do different jobs. The card plots **one number per unit** — the
z-marginal ∑|ψ|² — because that is all that can honestly fill in live. The volume below needs every
slice, so it appears when the sweep is done.
"""

#%% sweep id=volume chunk=8 cluster=slurm
NZ = 64          # planes through the orbital
ZR = 45.0        # half-height of the volume, in Bohr radii

# 4f_x(x²−3y²) — six alternating lobes, and the shape actually CHANGES as you fly through it.
#
# The unit returns the FIELD, so it is stored raw and mmaps: `volume[32].value[80, :]` reads one
# row of one plane without materializing 6 MB. What the card plots is the summary beside it.
volume = @sweep(paramgrid(z = range(-ZR, ZR; length = NZ));
                summary = v -> sum(abs2, v),
                plot = rows -> echart(Dict(
                    "backgroundColor" => "transparent",
                    "animation" => false,
                    "grid"    => Dict("left" => 68, "right" => 20, "top" => 30, "bottom" => 30),
                    "tooltip" => Dict("trigger" => "axis"),
                    "xAxis"   => Dict("type" => "value", "name" => "z", "min" => -ZR, "max" => ZR),
                    "yAxis"   => Dict("type" => "log", "name" => "∑|ψ|²"),
                    "series"  => [Dict("type" => "line", "showSymbol" => true, "symbolSize" => 5,
                                       "connectNulls" => false, "areaStyle" => Dict("opacity" => 0.18),
                                       "data" => [[r.params.z, r.summary] for r in rows])]))) do p
    using SweepDemo
    SweepDemo.orbital_slice(; n = 4, l = 3, m = 3, z = p.z,
                            npix = 160, extent = 45.0, ms = 800).psi
end

#%% code id=flythrough
# Building the volume genuinely needs every plane, so this is the one cell that materializes result
# data — and it says so: `Sweep.load` is the deliberate bulk path, and it would refuse if the sweep
# were larger than `max_bytes`. Everything above it read summaries.
#
# The signed cube root is a DISPLAY transform: ψ spans three decades between the mid-plane and the
# edge of the volume, so on a linear scale the outer slices would be black. Cube root is monotonic
# and sign-preserving, so it compresses the range without moving a single nodal surface.
squash(p) = sign.(p) .* abs.(p) .^ (1 / 3)

if volume.done < volume.total
    @md"""**$(volume.done)/$(volume.total)** planes so far, `$(volume.state)` —
    the card above is the live view; this fills in once the sweep settles."""
else
    # NO `times=`: the sweep axis here is SPACE, not time. `times` are playback timestamps in
    # seconds, so z ∈ [-45, 45] would ask for a 90-second flythrough and silently override `fps`.
    #
    # `:aurora` is diverging about a DARK centre — zero is where nothing is, so it gets the black
    # and the lobes get the colour. The sign change is the physics; |ψ|² would erase it.
    frames = squash.(Sweep.load(volume))
    ax = range(-45, 45; length = size(first(frames), 1))
    animate(frames; clim = :symmetric, colormap = :aurora, x = ax, y = ax, fps = 24,
            title = "ψ₄f x(x²−3y²) · flying through z = -45 … 45 a₀", height = 460)
end

#%% md id=h_chaos
@md"""
## Two axes

A grid with two axes is a surface. Each unit iterates a logistic map whose growth rate alternates
between `a` and `b` and reports its Lyapunov exponent — negative settles, positive is chaotic — and
the boundary between them is the picture.

It also shows the two rates code runs at: `using` in the body is lifted out and loaded once per
process, while `setup = begin … end` is chunk-level init, run once per scheduler job before any of
its units.
"""

#%% sweep id=chaos chunk=96 cluster=slurm
NG = 48                          # grid is NG × NG points
AX = range(2.6, 4.0; length = NG)

chaos = @sweep(paramgrid(a = AX, b = AX);
               # One number per unit, kept in the manifest — this is what the heatmap draws, and
               # why watching a 2304-unit sweep costs manifests rather than results.
               summary = v -> v.λ,
               # Chunk-level init: once per scheduler job, before any of its units.
               setup = begin
                   const SEQ = "AABAB"
                   verdict(λ) = λ > 0 ? :chaotic : :settled
               end,
               plot = rows -> echart(Dict(
                   "backgroundColor" => "transparent",
                   "animation" => false,
                   "grid"    => Dict("left" => 52, "right" => 82, "top" => 24, "bottom" => 34),
                   "tooltip" => Dict("position" => "top"),
                   "xAxis"   => Dict("type" => "category", "name" => "a",
                                     "data" => [round(x; digits = 3) for x in AX]),
                   "yAxis"   => Dict("type" => "category", "name" => "b",
                                     "data" => [round(x; digits = 3) for x in AX]),
                   # Dark through the settled region so the chaotic filaments are what you see;
                   # nothing in the ramp approaches white, which would otherwise dominate the card.
                   "visualMap" => Dict("min" => -1.5, "max" => 0.7, "calculable" => true,
                                       "orient" => "vertical", "right" => 2, "top" => "middle",
                                       "textStyle" => Dict("color" => "#6a7090"),
                                       "text" => ["chaotic", "settled"],
                                       "inRange" => Dict("color" =>
                                           ["#05070d", "#0d1a2e", "#14324f", "#1d5470",
                                            "#2b7d6f", "#8a7a1e", "#9c3a2c"])),
                   "series"  => [Dict("type" => "heatmap", "progressive" => 0,
                                      "itemStyle" => Dict("borderWidth" => 0),
                                      "data" => [[(i - 1) % NG, (i - 1) ÷ NG, r.summary]
                                                 for (i, r) in enumerate(rows) if r.status == "ok"])]))) do p
    using SweepDemo
    SweepDemo.lyapunov(; a = p.a, b = p.b, seq = SEQ, iters = 1500)
end

#%% md id=h_breaker
@md"""
## When it goes wrong

Three things a sweep has to survive without anyone watching it: a body that is simply broken,
units the scheduler kills, and a scale at which the display itself would otherwise fall over.
Only the walltime one needs the cluster.

### A body that is broken

The failure worth designing against: submit thousands of units, wait a day, discover the body was
broken all along. A fresh sweep releases one probe chunk and holds the rest until it reports, so a
sweep that is failing early stops itself rather than spending the allocation proving the point.
"""

#%% sweep id=breaker cluster=here
# 60 units, of which only the first probe chunk will ever run. `cluster=here` on the header runs
# them as local processes — the same cell, no scheduler — so this costs a handful of Julia starts.
broken = @sweep(paramgrid(x = 1:60)) do p
    error("typo in the body: no method matching frobnicate")
end

#%% md id=h_walltime
@md"""
### Units that are killed, not failed

A unit that outruns its walltime is **killed**, so it writes no result and no error. Nothing
distinguishes it from a unit that was never attempted, which is why the reconciler counts attempts
— without a budget it would resubmit the same doomed work forever.

These units ask for 20 seconds and then sleep for 60. Watch until the attempts are spent: the sweep
lands on **`:exhausted`**, which reads differently from `:blocked` on purpose. Nothing is wrong with
the *code*; it outran its *resources*, and the fix is a longer walltime.

The 20 seconds and the `short` partition are set on **this cell**, overriding the `slurm` cluster's
own 10 minutes — open the ⚙ to see it. Overrides are not part of a sweep's key, so raising the
walltime resumes rather than discarding the units that already survived at the old one.
"""

#%% sweep id=walltime cluster=slurm partition=short walltime=00:00:20
# The walltime and partition on this cell's header OVERRIDE the cluster's own (⚙ above). They are
# not part of the sweep's key, so raising the walltime resumes rather than starting over.
killed = @sweep(paramgrid(x = 1:4); setup = "using SweepDemo") do p
    SweepDemo.work((; x = p.x, hang_s = 60))     # asks for 20s, sleeps 60 — SLURM kills it
end

#%% md id=h_scale
@md"""
### Four thousand units

The tile grid **bins** units to a fixed budget, so the display costs the same at ten units and at
ten million. Binning keeps failure *clustering* legible: a bad region of the parameter space still
reads as a red band rather than dissolving into an average.
"""

#%% sweep id=scale cluster=here
big = @sweep(paramgrid(x = 1:4000)) do p
    # A whole region of the parameter space is broken, which is what clustering should reveal.
    2200 <= p.x <= 2600 && error("bad region")
    p.x
end

#%% md id=h_control
@md"""
## Taking control back

The card carries buttons for these, and they are callable too. They stay module-qualified on
purpose: `reset!` and `cancel!` are names your own packages may well export, and a helper injected
into every notebook would shadow them silently.

- `Sweep.retry_failed!(scan)` clears the errored units so the next run re-attempts them. Errors are
  never retried automatically: a unit that threw will usually throw again, and quietly re-running
  thousands of them spends an allocation on a deterministic bug.
- `Sweep.cancel!(scan)` stops a sweep durably — the marker survives a restart, so reopening the
  notebook will not quietly resubmit what you stopped. `Sweep.resume!(scan)` lifts it.
- `Sweep.reset!(scan)` drops every unit and its submission history, so the next run goes from cold.
"""

# ╔═╡ Slate.clusters · compute targets (⎈ on a sweep cell)
#   [slurm]
#   kind = slurm
#   host = slate-slurm
#   root = /Users/kburke/devel/KaimonSlate.jl/.claude/worktrees/feat+batch-fabric/dev/slurm-harness/scratch/cas
#   root_remote = /scratch/cas
#   project = /Users/kburke/devel/KaimonSlate.jl/.claude/worktrees/feat+batch-fabric/dev/sweepdemo
#   payload = /scratch/src/slatetask.jl
#   partition = compute
#   walltime = 00:10:00
#   cpus = 1
#   mem = 512M
#   chunk = 10
#   partitions = compute,short
#   max_walltime = 24:00:00
#   note = the Docker harness in dev/slurm-harness
#   [here]
#   kind = local
#   root = /Users/kburke/.cache/kaimonslate/sweepdemo
#   project = /Users/kburke/devel/KaimonSlate.jl/.claude/worktrees/feat+batch-fabric/dev/sweepdemo
#   chunk = 10
#   note = no scheduler - the same cells as local processes
# ╚═╡
# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = c9a73fa9-f90e-4907-947b-04344d988ea2
# ╚═╡
