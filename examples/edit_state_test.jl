try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Cell edit-state fixture

A deliberately tiny reactive pair (`acell` → `bcell`) for exercising the badge states by hand.
`edited` must mean exactly one thing: **this browser has typing that hasn't been applied.**

Things to try:

- Edit a cell from an agent while its editor is open and untouched → stays `stale`/`fresh`,
  the editor fast-forwards. It must never read `edited`.
- Add a trailing blank line and nothing else → not an edit; the badge must not change.
- Type something real → `edited`; running an unrelated cell must not clear it.
- Undo back to the saved source → `edited` lifts on its own.
- Type, then have an agent edit the same cell → the reconcile modal offers mine vs theirs,
  and your text is never overwritten underneath you.
"""

#%% code id=acell
a = 1

#%% code id=bcell
b = a * 10

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 24968fa2-bbf5-4d48-86f1-f01c06209b17
# ╚═╡
