try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=title
@md"""
# Beam deflection

A cantilever under a point load. Move the controls and the profile redraws.
"""

#%% code id=controls
@bind load Slider(1:0.5:20; default = 8, label = "load (kN)")
@bind span Slider(1:0.5:10; default = 6, label = "span (m)")

#%% code id=profile
# Deflection of a cantilever with a point load at the free end.
x = range(0, span; length = 120)
E, I = 210e6, 3.2e-4                       # kPa, m^4
δ = [(load * xi^2) * (3span - xi) / (6E * I) for xi in x]
echart(:line, collect(x), δ * 1000;
       title = "Deflection profile", xname = "x (m)", yname = "δ (mm)")

#%% code id=summary
slate_table(["quantity", "value"],
            [["tip deflection (mm)", round(δ[end] * 1000; digits = 3)],
             ["max moment (kNm)", round(load * span; digits = 2)],
             ["span (m)", span]])

#%% md id=exercise_note
@md"""
## Your turn

Implement the second-moment-of-area for a rectangular section.
"""

#%% code id=ex_inertia workbook
function inertia(b, h)
    missing
end

#%% code id=try_inertia workbook
inertia(0.05, 0.20)

#%% code id=chk_inertia
isequal(inertia(0.05, 0.20), 0.05 * 0.20^3 / 12) ? "✓ correct" : "not yet — try again"

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 58e0686a-4512-47ad-82ab-22a9aa0622ea
# ╚═╡
