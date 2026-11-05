try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=cover bg=aurora layout=title
@md"""
# Damped Oscillators
### a five-minute tour
"""

#%% md id=n_cover notes
@md"""
Open with the spring on the desk. Ask who has seen a car's suspension bounce.
"""

#%% md id=motion
@md raw"""
## The motion

$$\term{x}{x(t)} = \term{envelope}{e^{-\gamma t}}\,\cos(\term{freq}{\omega_d}\, t)$$

::: incremental
- the cosine swings at $\term{freq}{\omega_d}$
- the envelope shrinks at rate $\gamma$
- a larger $\gamma$ settles sooner
:::
"""

#%% code id=motion_plot hidecode column=2
let t = collect(range(0, 12; length = 600)), γ = 0.25, ωd = 2.0
    env = exp.(-γ .* t)
    echart(series(:line, t, env .* cos.(ωd .* t); name = "x", showSymbol = false),
           series(:line, t, env; name = "envelope", showSymbol = false, lineStyle = (width = 2, type = :dashed)),
           series(:line, t, -env; name = "envelope", showSymbol = false, lineStyle = (width = 2, type = :dashed));
           legend = false, height = 420)
end

#%% md id=n_motion notes
@md"""
Point at the dashed envelope before the oscillation.
"""

#%% md id=reading layout=center
@md raw"""
## Reading the equation

$$\braceat{1}{\term{inertia}{m\ddot x}}{inertia} + \braceat{2}{\term{damping}{c\,\dot x}}{friction} + \braceat{3}{\term{spring}{k\,x}}{restoring} = 0$$

::: {.step .fade step=3}
Nothing pushes from outside: the three forces balance
:::
"""

#%% md id=derivation layout=center
@md raw"""
## Naming the rates

::: derive
$$\term{inertia}{m\ddot x} + \term{damping}{c\,\dot x} + \term{spring}{k\,x} = 0$$

$$\term{inertia}{\ddot x} + \term{damping}{\tfrac{c}{m}\,\dot x} + \term{spring}{\tfrac{k}{m}\,x} = 0 \qquad \note{divide by m}$$

$$\term{inertia}{\ddot x} + \term{damping}{2\gamma\,\dot x} + \term{spring}{\omega_0^2\,x} = 0 \qquad \note{name the rates}$$
:::
"""

#%% md id=close bg=nebula layout=section
@md"""
## Questions
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 799926cb-49d7-479a-a47e-6716fd02a343
#   format = 2
# ╚═╡
