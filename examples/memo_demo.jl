#%% md id=intro
# 💾 Durable cell memoization

An **expensive** code cell (measured runtime ≥ 400 ms) is cached to disk keyed by a *total*
digest of everything that could change its result:

- the cell's own source + the sources of its transitive upstream cells,
- the values of any `@bind` widgets it reads,
- the Revise-tracked `src/` of the developed project(s), and
- the resolved `Manifest.toml` (package versions).

When you reopen the notebook (or the worker restarts), a matching entry is **restored** — its
result *and* the globals it defined come back with **no recompute**. Change any input and the
key changes, so a stale result is never silently served.

Watch the server log while (re)running: a cold run logs `slate memo: cached`, a warm reopen
logs `slate memo: restored (no recompute)`.

#%% md id=h_expensive
## An expensive, cacheable cell

Pure, deterministic, no `@bind` / `opaque` / `nocache` — so it's eligible. It sleeps + crunches
for well over the 400 ms threshold and assigns the global `heavy`; on a warm reopen that global
is restored from disk with no recompute.

#%% code id=expensive
# ~700 ms of "work": deterministic so a restored value is identical to a recomputed one.
heavy = let acc = 0.0
    for i in 1:20
        sleep(0.03)
        acc += sum(sin, (i * 1000):(i * 1000 + 5000))
    end
    round(acc; digits = 4)
end

#%% md id=h_downstream
## A cheap downstream cell

This depends on `heavy`. On a warm reopen the expensive cell is restored (its global included),
so this recomputes trivially against the restored value — the upstream never re-crunches.

#%% code id=downstream
"downstream sees heavy = $(round(heavy; digits = 2))"
