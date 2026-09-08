try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Live updates

A value you push to, a button that runs an action, and a long cell that reports progress
while it works.
"""

#%% code id=level
@reactive level = 0

#%% code id=gauge
# Reads `level`, so every push above re-renders just this cell.
echart(:bar, ["sweep"], [level]; title = "Live level")

#%% code id=go
@bind go Button("Sweep")

#%% code id=runner
@onclick go for v in 0:2:100
    level[] = v
    pause(0.05)
end

#%% code id=progress
# A long cell that reports how far it has got, rather than sitting silent.
total = 40
acc = 0.0
for i in 1:total
    acc += sqrt(i)
    slate_progress(i / total; msg = "reducing $(i)/$(total)")
    sleep(0.03)
end
round(acc; digits = 3)

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 6ae70482-2d73-4c80-8323-3eed1e0bc661
# ╚═╡
