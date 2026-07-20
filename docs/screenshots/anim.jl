try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Animation — `animate`

Precompute a stack of frames **once**, then play them back in the browser on a WebGL
canvas — nothing touches Julia during playback, so a slow simulation still plays at 60 fps.
"""

#%% code id=frames
# A little moving-gaussian field: heavy-ish to compute, cheap to play back.
xs = range(-3, 3; length = 90)
frames = [[exp(-((x - cos(t))^2 + (y - sin(t))^2)) for x in xs, y in xs]
          for t in range(0, 2π; length = 48)]
length(frames)

#%% code id=anim
anim = animate(frames; x = xs, y = xs, title = "moving gaussian", clim = :global)

#%% code id=t
@bind fr playhead(anim)          # driven: receives the current frame index during playback

#%% code id=readout
"frame $fr / $(length(frames))"

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 5050792c-ae09-432e-b9ff-17206e17fda0
# ╚═╡
