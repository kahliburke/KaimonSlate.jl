#%% md id=intro
# 🖧 Region layout test — local · rega · regb · regd

Open the **DAG pane** (🕸 in the topbar). Cells are spread across **four compute envs** (the local
kernel plus regions `rega`, `regb`, `regd`) with several **cross-region dependencies**, so the pane
exercises:

- **Grid packing** — the four envs arrange as a **2×2 of quadrants** (in a tall/right dock), not four
  tall swimlanes; resize/redock the pane and the grid re-fits (single row when wide).
- **Boundary-transfer routing** — the cross-region edges **bend around** node boxes and zone-header
  text instead of cutting straight through, and heavily-connected regions sit adjacent.

You don't have to run it — the layout is built from the static dependency graph. To also exercise the
**aliveness dots + reap** (and actually execute the cells), define real `rega`/`regb`/`regd` regions in
the front-page **🖧 Remotes** dialog first.

#%% code id=seed
seed = 100

#%% md id=h_rega
## rega — a producer subgraph

#%% code id=a1 region=rega
a1 = seed + 1
#%% code id=a2 region=rega
a2 = a1 * 2
#%% code id=a3 region=rega
a3 = a2 + a1
#%% code id=a4 region=rega
a4 = a3 - 1
#%% code id=a5 region=rega
a5 = a4 + a2
#%% code id=a6 region=rega
a6 = a5 + a3

#%% md id=h_regb
## regb — consumes rega, produces more

#%% code id=b1 region=regb
b1 = a3 + 1          # ← transfer rega → regb
#%% code id=b2 region=regb
b2 = b1 * 2
#%% code id=b3 region=regb
b3 = b2 + b1
#%% code id=b4 region=regb
b4 = b3 + a5         # ← transfer rega → regb
#%% code id=b5 region=regb
b5 = b4 + b3

#%% md id=h_regd
## regd — fed by both regb and rega

#%% code id=d1 region=regd
d1 = b2 + 1          # ← transfer regb → regd
#%% code id=d2 region=regd
d2 = d1 + a6         # ← transfer rega → regd
#%% code id=d3 region=regd
d3 = d2 * 2
#%% code id=d4 region=regd
d4 = d3 + d1
#%% code id=d5 region=regd
d5 = d4 + b5         # ← transfer regb → regd

#%% md id=h_local
## local — collects from every region

#%% code id=result
result = a6 + b5 + d5   # ← transfers rega, regb, regd → local
