try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Damping scan

The peak displacement of a driven, damped oscillator, over a grid of damping and drive frequency.
"""

#%% code id=model
function peak(c, ω; m = 1.0, k = 4.0, dt = 1e-3, T = 40.0)
    x, v, best = 0.0, 0.0, 0.0
    for i in 1:round(Int, T / dt)
        a = (cos(ω * i * dt) - c * v - k * x) / m
        v += a * dt
        x += v * dt
        i * dt > T / 2 && (best = max(best, abs(x)))
    end
    return best
end

#%% job id=scan cluster=lab chunk=4
scan = @sweep paramgrid(; c = 0.1:0.1:0.8, ω = 1.0:0.1:3.0) do p
    sleep(1.5)
    peak(p.c, p.ω)
end

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 5b0f3c1e-7d2a-4c51-9e8b-2f6a1d4c8e90
#   format = 2
# ╚═╡
