# Parallel-execution readiness — the pure core of the in-worker dataflow scheduler. Given the stale
# cells in DOCUMENT ORDER with their dependency info, it computes, for each cell, the set of EARLIER
# cells that must finish before it may start. A cell is "ready" once all its blockers are done; cells
# that block on each other run serially, the rest run concurrently. Pure + dependency-free so it's
# unit-tested directly (test/test_parsched.jl) and shared by the worker scheduler.
#
# The rule (document order is the safety backstop — precise deps BUY parallelism, their absence only
# costs overlap, never correctness):
#   For an EARLIER cell `e` and a later cell `c`, `c` must wait for `e` iff ANY of:
#     • `e` is opaque (a `using`/import or un-analyzable cell) — a barrier: everything after waits;
#     • `c` is opaque — it waits for everything before it;
#     • `c` depends on `e` (data dependency: e ∈ c.deps, or e writes something c reads);
#     • `c` and `e` write the SAME global (write-write conflict → document order decides the winner).
#   Otherwise `c` and `e` are independent and may run at the same time.

# Makie (and most plotting) touches PROCESS-GLOBAL, non-thread-safe state — the theme observable, the
# current scene/figure, the display stack — whose Observables listener vectors resize non-atomically.
# The dataflow analysis can't see those shared globals (they're library internals, not notebook
# bindings), so two independent plotting cells look co-runnable and race
# (`ConcurrencyViolationError: Vector can not be resized concurrently`, deep in Observables). We give
# every graphics cell a synthetic shared WRITE (`_GRAPHICS_SENTINEL`), so the existing write-write rule
# serialises any two of them while pure-compute cells still run in parallel. Over-approximate on purpose:
# a false positive costs a little overlap, a miss risks a crash. High-signal tokens — scene/figure/theme
# constructors + display, and the `!` plotting verbs (rarely variable names) — each as a CALL `(`.
const _GRAPHICS_SENTINEL = Symbol("##slate_graphics##")
const _GRAPHICS_RE = r"\b(?:Figure|Axis3?|LScene|Scene|PolarAxis|Colorbar|Legend|set_theme!|update_theme!|with_theme|set_window_config!|record|current_figure|current_axis|display|(?:lines|scatter|scatterlines|heatmap|surface|contour|contourf|band|poly|mesh|meshscatter|image|barplot|hist|density|arrows|series|stairs|stem|errorbars|boxplot|violin|hlines|vlines|ablines|text|wireframe|streamplot|spy|volume|voronoiplot|rangebars|annotations)!)\s*\("
_uses_shared_graphics(src::AbstractString) = occursin(_GRAPHICS_RE, src)

"Minimal per-cell info the scheduler needs (built from a Cell's deps/reads/writes/flags)."
struct ParCell
    id::String
    deps::Set{String}     # direct upstream cell ids (most-recent-writer)
    reads::Set{Symbol}
    writes::Set{Symbol}
    opaque::Bool          # `using`/import barrier or otherwise un-analyzable → serialize conservatively
end

# `cells` MUST be in document order. Returns id → Set of earlier-cell ids it must wait for.
function par_blockers(cells::Vector{ParCell})
    blockers = Dict{String,Set{String}}()
    for (i, c) in enumerate(cells)
        b = Set{String}()
        @inbounds for j in 1:(i - 1)
            e = cells[j]
            if e.opaque || c.opaque || (e.id in c.deps) ||
               !isdisjoint(c.writes, e.writes) ||      # write-write conflict
               !isdisjoint(c.reads, e.writes)          # c reads what e writes (data dep, belt-and-suspenders)
                push!(b, e.id)
            end
        end
        blockers[c.id] = b
    end
    return blockers
end

# Would running `cell_ids` concurrently respect the blocker graph? (A sanity predicate for tests /
# assertions: a set is co-runnable iff no member blocks another.) `blockers` from `par_blockers`.
function co_runnable(ids, blockers)
    s = Set(ids)
    for id in s, b in get(blockers, id, ())
        b in s && return false
    end
    return true
end

# ── The dataflow execution loop (pure: no gate / no capture dependency) ──────────────────────────
# Drive a batch of `cells` (DOCUMENT ORDER) to completion, running independent cells CONCURRENTLY on
# spawned tasks while honouring `par_blockers` — a cell launches only once every earlier cell that
# blocks it has FINISHED. `npool` bounds how many run at once. `evalfn(id)` does the actual work for a
# cell (in the worker: `run_capture` with a `DemuxCapture`); `ondone(id, result)` is called on the
# scheduler task the instant a cell finishes (in the worker: stream the result on the gate). A cell's
# evalfn throwing is caught and the exception is delivered as that cell's `result` — one bad cell never
# stalls the batch. Returns id → result for every cell.
#
# Concurrency safety: ONLY this (the scheduler) task mutates the bookkeeping sets and `results`; the
# spawned tasks touch nothing shared except `put!`-ing their (id, result) onto a Channel. The blocker
# graph is a DAG over the batch (blockers are strictly-earlier cells), so the loop always drains — no
# deadlock even on a pathological dependency chain.
function run_scheduled(cells::Vector{ParCell}, npool::Integer, evalfn, ondone = (_id, _r) -> nothing;
                       onspawn = (_id, _t) -> nothing)
    blockers = par_blockers(cells)
    order = [c.id for c in cells]
    cap = max(1, Int(npool))
    done = Set{String}()
    launched = Set{String}()
    running = Ref(0)
    results = Dict{String,Any}()
    completions = Channel{Tuple{String,Any}}(length(cells))

    fill_slots! = function ()
        for id in order
            (id in launched) && continue
            running[] >= cap && break
            all(b -> b in done, blockers[id]) || continue
            push!(launched, id); running[] += 1
            t = Threads.@spawn begin
                local r
                try; r = evalfn(id); catch e; r = e; end
                put!(completions, (id, r))
            end
            try; onspawn(id, t); catch; end   # hand the task to the caller (cancellation registry)
        end
    end

    fill_slots!()
    remaining = length(cells)
    while remaining > 0
        (id, r) = take!(completions)
        results[id] = r
        running[] -= 1
        push!(done, id)
        try; ondone(id, r); catch; end
        remaining -= 1
        fill_slots!()
    end
    return results
end
