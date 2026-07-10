#%% md id=intro
# DAG edge cases — reactive-engine stress notebook

Each section exercises a dependency-analysis edge case the engine must get right.
**How to use it:** run all, then edit the flagged cells and watch what restales —
each section's prose says what *should* happen. The perf section at the bottom
times the graph machinery on synthetic notebooks with hundreds of interrelated
cells.

#%% md id=sec_macro
## 1 · Macro-hidden writes (`@kwdef`, `@enum`)

A macro that *defines* names hides them from static analysis — only macro
expansion recovers them. **Edit the default `rate` below** (e.g. `0.5 → 0.9`):
the `cfg` cell and the readout must restale and re-run. Before macro-aware deps,
this edit was dead reactivity.

#%% code id=kwdef_struct
Base.@kwdef struct SimConfig
    rate::Float64 = 0.5
    steps::Int = 100
end

#%% code id=kwdef_reader
cfg = SimConfig()

#%% md id=md_kwdef_out
Config says: rate **{{ cfg.rate }}**, steps **{{ cfg.steps }}**.

#%% code id=enum_def
@enum Phase warmup running cooldown

#%% code id=enum_reader
phase = running
"current phase: $phase ($(Int(phase)))"

#%% md id=sec_nbmacro
## 2 · Notebook-defined macros

`@double` doesn't exist until its cell runs, so its callers resolve *post-drain*
(`refine_macros!`). **Edit the macro body** (e.g. `2x → 3x`): `doubled` must
restale. **Edit `base_val`**: `doubled` must also restale (the read edge survives
expansion).

#%% code id=macro_def
macro double(name, x)
    esc(:($name = 2 * $x))
end

#%% code id=macro_input
base_val = 21

#%% code id=macro_call
@double doubled base_val

#%% code id=macro_reader
"doubled = $doubled"

#%% md id=sec_readonly
## 3 · Read-only macros must not fabricate producers

`@show` only *reads* `shared_v`. If expansion wrongly recorded a write, this cell
would collide with the real definer (a multidef warning) or steal its readers.
No warning chip should appear on either cell.

#%% code id=shared_def
shared_v = 7

#%% code id=readonly_macro
@show shared_v

#%% md id=sec_mutation
## 4 · Mutation edges (writer vs. mutator)

`push!` mutates without defining: the sum cell must depend on the *mutating*
cell (not just the definer), and the mutator must not count as a second definer
(no multidef chip). **Edit the pushed value**: the sum restales.

#%% code id=mut_def
samples = [1.0, 2.0, 3.0]

#%% code id=mut_push
push!(samples, 40.0)

#%% code id=mut_reader
"samples total: $(sum(samples))"

#%% md id=sec_multidef
## 5 · Multi-definition collision (intentional footgun)

Both cells below define `collide` — last writer wins, and edits to the first
look like dead reactivity. The engine should flag `collide` with a multidef
warning chip on both cells.

#%% code id=collide_a
collide = "from cell A"

#%% code id=collide_b
collide = "from cell B"

#%% md id=sec_barrier
## 6 · Barriers: bare `using` → progressive refinement

`using Statistics` is an opaque barrier *until it runs*; then its true exports
resolve and only cells that use `mean`/`std` keep the edge. After one full run,
**editing the `using` cell must NOT restale `indep`** (it uses nothing from
Statistics).

#%% code id=bare_using
using Statistics

#%% code id=uses_stats
stats_summary = (μ = mean(samples), σ = std(samples))

#%% code id=indep
indep = "I don't use Statistics — refinement should cut my edge to the barrier"

#%% md id=sec_fork
## 7 · Fork/join parallelism

`left`/`right` both read `fork_base` but are independent of each other — with
parallel cells enabled they overlap (each sleeps 1s; the pair should take ~1s,
not ~2s). `join` waits for both.

#%% code id=fork_base
fork_base = 10

#%% code id=fork_left
left = (sleep(1.0); fork_base + 1)

#%% code id=fork_right
right = (sleep(1.0); fork_base * 2)

#%% code id=fork_join
"join: left=$left right=$right → $(left + right)"

#%% md id=sec_perf
## 8 · Graph-machinery performance

Synthetic notebooks built in-memory (never evaluated — this times *analysis*,
not eval): a linear chain (worst-case blast radius) and a diamond mesh (each
cell reads two earlier ones — dense edges). Drag the slider to scale.

#%% code id=perf_n
@bind perf_n Slider(100:100:1000, default = 300, label = "cells")

#%% code id=perf_build
perf_src = let n = Int(perf_n)
    io = IOBuffer()
    for i in 1:n   # linear chain: x1 → x2 → … → xn
        rhs = i == 1 ? "1" : "x$(i-1) + 1"
        print(io, "#%% code id=chain$i\nx$i = $rhs\n")
    end
    for i in 1:n   # diamond mesh: yi reads two earlier ys
        rhs = i <= 2 ? "$i" : "y$(i-1) + y$(i>>1)"
        print(io, "#%% code id=mesh$i\ny$i = $rhs\n")
    end
    String(take!(io))
end;

#%% code id=perf_time
# The worker env carries this notebook's deps but not the KaimonSlate package itself — walk up
# from the notebook project to the repo root and put IT on LOAD_PATH so the engine is importable
# (dev stress notebook only; in-process kernels already have KaimonSlate loaded).
if isdefined(Main, :SlateWorker)
    let root = Main.SlateWorker.PARENT_PROJECT[]
        while !isempty(root) && !isfile(joinpath(root, "src", "KaimonSlate.jl"))
            up = dirname(root)
            root = up == root ? "" : up
        end
        !isempty(root) && !(root in LOAD_PATH) && push!(LOAD_PATH, root)
    end
end
import KaimonSlate
perf_report = KaimonSlate.ReportEngine.parse_report(perf_src)
t_build = @elapsed KaimonSlate.ReportEngine.build_dependencies!(perf_report)
t_rebuild = @elapsed KaimonSlate.ReportEngine.build_dependencies!(perf_report)   # warm (bind cache hit)
t_blast_head = @elapsed blast = KaimonSlate.ReportEngine.dependents_of(perf_report, Set(["chain1"]))
t_blast_tail = @elapsed KaimonSlate.ReportEngine.dependents_of(perf_report, Set(["mesh$(Int(perf_n))"]))
t_edit = @elapsed KaimonSlate.ReportEngine.update_source!(perf_report,
    replace(perf_src, "x1 = 1" => "x1 = 2"))
slate_table([
    (metric = "cells (chain + mesh)", value = 2 * Int(perf_n)),
    (metric = "cold build_dependencies! (ms)", value = round(1000t_build; digits = 2)),
    (metric = "warm rebuild (ms)", value = round(1000t_rebuild; digits = 2)),
    (metric = "blast radius from chain head (ms)", value = round(1000t_blast_head; digits = 3)),
    (metric = "blast radius from mesh tail (ms)", value = round(1000t_blast_tail; digits = 3)),
    (metric = "head-edit update_source! (ms)", value = round(1000t_edit; digits = 2)),
    (metric = "cells restaled by head edit", value = length(blast)),
])

#%% md id=sec_footgun
## 9 · Ordering footgun (the `backref` diagnostic)

A cell that reads a name defined *below* it silently gets last-run semantics —
document order can't represent the edge. Uncomment to see it: `early_reader`
errors on a fresh run, works on re-run, editing `late_writer` never restales it,
**and a ⇅ chip appears on `early_reader`** naming the definer below (click to
jump). Function-body forward refs (`f() = g()` with `g` below) are exempt.

#%% code id=early_reader
# early_reader = late_writer + 1   # ← uncomment to demo the footgun

#%% code id=late_writer
late_writer = 99
