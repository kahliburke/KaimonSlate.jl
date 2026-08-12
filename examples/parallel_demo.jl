#%% md id=intro
# Parallel cell execution — CPU demo

`cpu_a` and `cpu_b` are **independent** CPU-bound cells (~2–4 s each). The heavy work
is a **compiled** `sum(f, range)` — NOT a top-level `for` loop, which Julia runs
*interpreted* (~100× slower). `combine` reads both, so it runs only after they finish.

Set the worker thread count in the Kaimon **Extensions tab → `u` on `slate`**:

- **1 compute thread** (`1,1`): `cpu_a`/`cpu_b` can't overlap on the CPU → total ≈ `2 × T`.
- **≥2 compute threads** (e.g. `4,1`): they run on separate OS threads → total ≈ `T`.

`combine` must still read the right `a + b` across threads — the cross-cell world-age
check. (Settings → Parallel cell execution **ON**, then **Run all**.)

#%% code id=cpu_a
# Independent CPU work (compiled — sum over a higher-order function), writes `a`.
a = sum(sin, 1:300_000_005)

#%% code id=f6ca05
1+38

#%% code id=cpu_b
# Independent CPU work, writes `b`. No data shared with cpu_a → may run on another thread.
b = sum(cos, 5:300_000_000)

#%% code id=combine
# Reads BOTH a and b → serialised after cpu_a and cpu_b (the cross-thread read check).
combined = a + b

#%% code id=report
"a=$(round(a; digits=4))  b=$(round(b; digits=4))  a+b=$(round(combined; digits=4))"

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   threads = 2,1
# ╚═╡
