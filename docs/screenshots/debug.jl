try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Stepping a simulation

A damped oscillator that blows up partway through a long run.
"""

#%% code id=model
gain_at(k) = k > 4000 ? 1.002 : 0.999

function advance(u, v, gain; dt = 0.01)
    v = gain * (v - u * dt)
    u = u + v * dt
    return u, v
end

#%% code id=run
u, v = 1.0, 0.0
peak = 0.0
for k in 1:5000
    global u, v, peak
    u, v = advance(u, v, gain_at(k))
    peak = max(peak, abs(u))
end
(u = u, peak = peak)

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = aa6d8b82-b66d-4cbc-8289-1cf036ccce2a
#   format = 2
# ╚═╡
