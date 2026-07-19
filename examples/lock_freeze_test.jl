try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 🔒 Lock / freeze round-trip test

This notebook checks that a **locked** cell keeps its **frozen value** when the notebook is
carried to a fresh environment — the two paths that reportedly leak re-execution:

1. **Standalone upload** — export this as a `.jl`, upload it to a running Slate server.
2. **One-liner download & run** — fetch the published `.jl` and run it against a fresh kernel.

The trick below is a **control vs. frozen** pair. Each holds a random token minted at run time:

- `control_token` is a normal cell — it **should** mint a new value on every fresh run.
- `frozen_token` is tagged `locked` — once frozen, it **must keep the same value** everywhere.

**How to read the result** (see the verdict cell at the bottom):

- ✅ Working: after a reopen / download-run, `control_token` changed but `frozen_token` did **not**.
- ❌ Leaked: `frozen_token` changed too — the lock did not survive the trip.
"""

#%% md id=how_to_lock
@md"""
## Setup (do this once in a live session)

1. Run all cells.
2. Note both tokens.
3. Lock the frozen cell: toggle its **🔒 lock** in the cell menu (or tag it `locked`). This stamps
   its `lockedkey=` and pins the frozen value in the memo store.
4. Export the standalone `.jl` (with embedded outputs) and/or publish it.
5. Reopen via upload or the download-and-run one-liner against a **fresh** kernel and compare.
"""

#%% code id=drift_n
drift_n = 2

#%% code id=drift_frozen frozenat=acc772e6f98aa444 locked lockedkey=b4db5fa1ec64d8f3
drift_frozen = "n=$(drift_n) · " * string(rand(UInt64); base = 16, pad = 16)

#%% code id=control
# NOT locked — a fresh random token every run. This is the control: if THIS value is identical
# after a reopen, the notebook never actually re-executed and the test is inconclusive.
for i in 1:5
    x = i+653
end
control_token = string(rand(UInt64); base = 16, pad = 16)

#%% code id=frozen frozenat=30d4aabad45c85a8 locked lockedkey=e58922d0a099976c
# Tagged `locked`. Once frozen in a live session, this exact token must be restored — not re-minted —
# on every subsequent open, including standalone upload and the download-and-run one-liner.
frozen_token = string(rand(UInt64); base = 16, pad = 16)

#%% code id=derived
# A downstream cell that consumes the frozen value, to confirm the cascade sees the FROZEN token
# (not a re-minted one). Its output should track `frozen_token` exactly.
derived_from_frozen = "derived(" * frozen_token * ")"

#%% md id=verdict
@md"""
## Verdict

Compare the tokens shown above against what you recorded in the live session:

| cell | expected after a fresh reopen |
|------|-------------------------------|
| `control_token` | **different** (proves the notebook re-executed) |
| `frozen_token`  | **identical** to the frozen value (lock held) |
| `derived_from_frozen` | wraps the **frozen** token, not a new one |

If `control_token` changed but `frozen_token` stayed put → locking works on this path.
If `frozen_token` changed → the freeze leaked through this path.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = nb_53402e1fcc30b318945dc917
# ╚═╡
