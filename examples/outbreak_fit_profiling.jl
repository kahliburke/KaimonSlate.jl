try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=title title
@md"""
# Calibrating an outbreak model
## Finding the slow parts with the profiler and JET, and fixing them
"""

#%% md id=intro
@md"""
We have four months of daily reported cases from an outbreak and want the parameters of an SEIR
model that reproduce them: the transmission rate β, the incubation rate σ, the recovery rate γ, and
the share of infections that get reported, ρ. There is no closed form, so the model is fitted by
running it many times and keeping the parameters whose curve sits closest to the data.

That makes speed the whole game. The first version below is written the way exploratory code
usually is, and it works. The rest of the notebook uses the profiler to find where its time goes,
JET to say why, and then fixes it, checking at each step that the answer does not change.

To follow along, open the profiler on a cell with the 🔥 button in its toolbar.
"""

#%% code id=deps
using CairoMakie, Random, Statistics, Printf

#%% code id=theme hidecode
CairoMakie.activate!()
set_theme!(theme_dark();
    backgroundcolor = :transparent,
    figure_padding = 8,
    Axis = (backgroundcolor = :transparent,
            xgridcolor = (:white, 0.08), ygridcolor = (:white, 0.08),
            leftspinevisible = false, rightspinevisible = false,
            topspinevisible = false, bottomspinevisible = false,
            xtickcolor = (:white, 0.4), ytickcolor = (:white, 0.4)),
    Legend = (backgroundcolor = :transparent, framevisible = false));

#%% md id=data_md
@md"""
## The outbreak

A town of a million people, ten initial infections, 120 days of reports. The reported counts are
noisy: each day's count scatters around the true number of new reported infections.
"""

#%% code id=data
u0 = (999_990.0, 0.0, 10.0, 0.0)          # susceptible, exposed, infectious, recovered
days = 120
observed = let β = 0.45, σ = 1 / 4, γ = 1 / 6, ρ = 0.3, dt = 0.01, rng = Xoshiro(7)
    S, E, I, R = u0
    out = Float64[]
    for d in 1:days
        S0 = S
        for _ in 1:round(Int, 1 / dt)
            inf = β * S * I / (S + E + I + R)
            S, E, I, R = S - dt * inf, E + dt * (inf - σ * E), I + dt * (σ * E - γ * I), R + dt * γ * I
        end
        c = ρ * (S0 - S)
        push!(out, max(0.0, round(c + sqrt(c + 1) * randn(rng))))
    end
    out
end
(days = length(observed), peak = maximum(observed), total = sum(observed))

#%% md id=draft_md
@md"""
## A first draft

The model as it might be written on a first pass. The parameters live in a struct, each step of
the integrator returns a fresh vector, and the trajectory is collected into an empty list. The
calibration draws random parameters and keeps the best, with a closure doing each trial.
"""

#%% code id=model_v1
struct SEIRParams
    β::Real      # transmission rate, per day
    σ::Real      # 1 / incubation period
    γ::Real      # 1 / infectious period
    ρ::Real      # share of infections reported
end

function seir_rhs(u, p)
    S, E, I, R = u
    infection = p.β * S * I / (S + E + I + R)
    [-infection, infection - p.σ * E, p.σ * E - p.γ * I, p.γ * I]
end

# Fourth-order Runge-Kutta with a fixed step, every state kept.
function simulate(p, u0, days; dt = 0.1)
    u = u0
    traj = []
    for step in 1:round(Int, days / dt)
        k1 = seir_rhs(u, p)
        k2 = seir_rhs(u .+ dt / 2 .* k1, p)
        k3 = seir_rhs(u .+ dt / 2 .* k2, p)
        k4 = seir_rhs(u .+ dt .* k3, p)
        u = u .+ dt / 6 .* (k1 .+ 2k2 .+ 2k3 .+ k4)
        push!(traj, u)
    end
    traj
end

# New reported infections each day: what left the susceptible pool, times the reporting share.
function daily_cases(p, u0, days; dt = 0.1)
    traj = simulate(p, u0, days; dt)
    per_day = round(Int, 1 / dt)
    cases = []
    prevS = u0[1]
    for d in 1:days
        s = traj[d * per_day][1]
        push!(cases, p.ρ * (prevS - s))
        prevS = s
    end
    cases
end

loss(p, u0, observed) = sum((daily_cases(p, u0, length(observed)) .- observed) .^ 2)

function calibrate(observed, u0; n = 3000, seed = 1)
    rng = Xoshiro(seed)
    best = Inf
    bestp = nothing
    trial = () -> begin
        p = SEIRParams(0.2 + 0.6rand(rng), 1 / (2 + 6rand(rng)), 1 / (3 + 9rand(rng)), 0.1 + 0.8rand(rng))
        l = loss(p, u0, observed)
        if l < best
            best = l
            bestp = p
        end
    end
    foreach(_ -> trial(), 1:n)
    bestp, best
end

#%% code id=fit_v1
fit_draft = calibrate(observed, collect(u0))

#%% md id=profile_md
@md"""
## Where does the time go?

Open the profiler on `fit_v1` and press **▶ Run and profile**. The cell runs as it always does,
under the sampler.

- The **flame graph** starts at the cell's line and goes down through `calibrate`, `loss`,
  `daily_cases` and `simulate` to `seir_rhs`. Almost all of the width is under the integrator.
- The bars carry **⤳** marks: time spent dispatching calls at runtime, because the compiler could
  not tell which method a call would need. There is a **♻** share too: garbage collection.
- The **hot lines** table puts the last line of `seir_rhs`, the one that builds the new vector, at
  the top, with about two fifths of the run on its own.

So the time goes on dispatch and on allocating. The profile shows where; it does not show why.

Add JET (the **＋ JET** button in the profiler's header, if it is not there yet) and press
**Compile**. JET analyses the cell without running it. Its findings land on the lines in the margin
and in **Details**, one entry per line of the notebook's code:

| line | finding | cause |
|---|---|---|
| `infection = p.β * S * I / …` in `seir_rhs` | runtime dispatch | `β::Real` is abstract: every field read has an unknown type |
| the `k1` … `u = u .+ …` lines in `simulate` | runtime dispatch | `seir_rhs` returns `Any`, so every broadcast on its result is dynamic |
| `push!(cases, …)`, and the `sum` in `loss` | runtime dispatch | `[]` is a `Vector{Any}`: everything read from it is `Any` |
| `best = Inf` in `calibrate` | boxed capture | `trial` reassigns `best` and `bestp`, so both live in a heap box |

A line can also say "N inside sum, promote…": calls into Base that dispatch because they were
handed `Any`. They go away with the line's own problem.

JET lists every finding, cheap or not. The profile says which matter: the dispatch findings sit on
the hottest lines, and the boxed capture is on a line that runs once per trial.
"""

#%% md id=tuned_md
@md"""
## The tuned version

One change per finding:

- **A concrete parameter type.** `Params{T}` stores four values of one concrete type, so the
  compiler knows what `p.β` is.
- **Tuples for the state.** The right-hand side returns an `NTuple{4}`, which lives in registers.
  No step allocates.
- **Only what is needed, preallocated.** The calibration only uses each day's cases, so the
  integrator writes those into a vector it is handed, instead of keeping every state.
- **A plain loop for the search.** `best` and `bestp` are ordinary locals.
"""

#%% code id=model_v2
struct Params{T<:Real}
    β::T
    σ::T
    γ::T
    ρ::T
end

@inline function rhs(u::NTuple{4,T}, p::Params{T}) where {T}
    S, E, I, R = u
    infection = p.β * S * I / (S + E + I + R)
    (-infection, infection - p.σ * E, p.σ * E - p.γ * I, p.γ * I)
end

@inline step_along(u, k, h) = map((ui, ki) -> ui + h * ki, u, k)

function daily_cases!(cases::Vector{T}, p::Params{T}, u0::NTuple{4,T}; dt::T = T(0.1)) where {T}
    per_day = round(Int, 1 / dt)
    u = u0
    prevS = u0[1]
    for d in eachindex(cases)
        for _ in 1:per_day
            k1 = rhs(u, p)
            k2 = rhs(step_along(u, k1, dt / 2), p)
            k3 = rhs(step_along(u, k2, dt / 2), p)
            k4 = rhs(step_along(u, k3, dt), p)
            u = map((ui, a, b, c, e) -> ui + dt / 6 * (a + 2b + 2c + e), u, k1, k2, k3, k4)
        end
        cases[d] = p.ρ * (prevS - u[1])
        prevS = u[1]
    end
    cases
end

function loss!(cases, p, u0, observed)
    daily_cases!(cases, p, u0)
    s = zero(eltype(cases))
    for d in eachindex(cases, observed)
        s += (cases[d] - observed[d])^2
    end
    s
end

function calibrate_tuned(observed::Vector{Float64}, u0::NTuple{4,Float64}; n = 3000, seed = 1)
    rng = Xoshiro(seed)
    cases = similar(observed)
    best = Inf
    bestp = Params(NaN, NaN, NaN, NaN)
    for _ in 1:n
        p = Params(0.2 + 0.6rand(rng), 1 / (2 + 6rand(rng)), 1 / (3 + 9rand(rng)), 0.1 + 0.8rand(rng))
        l = loss!(cases, p, u0, observed)
        if l < best
            best = l
            bestp = p
        end
    end
    bestp, best
end

#%% code id=fit_v2
fit_tuned = calibrate_tuned(observed, u0)

#%% md id=check_md
@md"""
Same seed, same draws, so the two searches must agree. Profile `fit_v2` and the ⤳ and ♻ marks
are gone: what is left is the arithmetic of the integrator. **Compile** reports nothing.
"""

#%% code id=check
let (p1, l1) = fit_draft, (p2, l2) = fit_tuned
    agree = all(isapprox.((p1.β, p1.σ, p1.γ, p1.ρ), (p2.β, p2.σ, p2.γ, p2.ρ)))
    (same_answer = agree, loss_draft = round(l1), loss_tuned = round(l2))
end

#%% md id=wide_md
@md"""
## What the speed buys

3,000 random draws is a coarse search; the draft could not afford more. The tuned version runs a
hundred thousand in about the time the draft took for three thousand.
"""

#%% code id=fit_wide
fit_wide = calibrate_tuned(observed, u0; n = 100_000, seed = 2)

#%% code id=params
let fmt(p) = @sprintf("β %.3f · incubation %.1f d · infectious %.1f d · reported %.0f%%", p.β, 1 / p.σ, 1 / p.γ, 100p.ρ)
    (draft = fmt(fit_draft[1]), wide = fmt(fit_wide[1]), data_came_from = fmt(Params(0.45, 1 / 4, 1 / 6, 0.3)))
end

#%% code id=plot
let fig = Figure(size = (900, 420)), ax = Axis(fig[1, 1]; xlabel = "day", ylabel = "reported cases")
    for (fit, label, color) in ((fit_draft, "3,000 draws", :orange), (fit_wide, "100,000 draws", :deepskyblue))
        p = fit[1]
        lines!(ax, 1:days, daily_cases!(zeros(days), Params(p.β, p.σ, p.γ, p.ρ), u0); color, linewidth = 2.5, label)
    end
    scatter!(ax, 1:days, observed; color = (:white, 0.7), markersize = 6, label = "reported")
    axislegend(ax; position = :rt)
    fig
end

#%% md id=fit_reading
@md"""
The wider search fits the reports far more closely, yet its rates differ from the ones the data
came from: a longer incubation with a shorter infectious period and a higher β. Case counts alone
pin down how fast the outbreak grew and how many were reported, and several combinations of
rates give the same curve. Telling them apart takes other data, such as the serial interval from
contact tracing. A fast model is what makes that question cheap to explore.
"""

#%% md id=recap
@md"""
## The loop

1. **Profile** the cell that is slow. The flame graph and hot lines say where the time goes; the
   ⤳, ♻ and ⚙ marks say what kind of time it is.
2. **Compile** with JET in the environment. Its findings say why, on the lines they come from,
   without running anything.
3. **Fix the findings on hot lines**, and leave the rest. Compile again to see a finding go.
4. **Profile again** and compare with the run before (**compare with…** in the header).

The profiling specialist (**＋ specialist**) works the same loop and asks before it changes a cell.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 34a383e6-83ac-436c-987d-e975d217ec91
#   format = 2
# ╚═╡
