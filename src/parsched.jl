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
