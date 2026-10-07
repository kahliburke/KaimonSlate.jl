try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=title title
@md"""
# Calibrating an outbreak model
## Finding the slow parts with the profiler and JET, and fixing them
"""

#%% md id=intro
@md"""
We have twenty weeks of daily reported cases from an outbreak in a town of a million people, and
want the parameters of an age-structured SEIR model that reproduce them: the transmission rate β,
the incubation rate σ, the recovery rate γ, and the share of infections that get reported, ρ.
Reports lag infections by a few days, so the model's infections pass through a reporting delay
before they are compared with the data. There is no closed form, so the model is fitted by running
it many times and keeping the parameters whose reports fit the data best.

The simulation is already written with care. The reporting delay was added later, quickly. The
rest of the notebook uses the profiler to see where the time goes, JET to say why, and fixes what
deserves fixing, checking that the answer does not change.

Open the profiler on a cell with the 🔥 button in its toolbar.
"""

#%% code id=deps
using CairoMakie, LinearAlgebra, Random, Statistics, Printf

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

#%% md id=town_md
@md"""
## The town

Nine age bands. People mix mostly with their own age and with the bands next to it, children most
of all, and the contact matrix `C` says how many contacts per day a person in one band has with
each other band. Susceptibility rises with age. The outbreak starts with ten infections among
people in their twenties.
"""

#%% code id=town
ages = ["0–9", "10–19", "20–29", "30–39", "40–49", "50–59", "60–69", "70–79", "80+"]
G = length(ages)
N = 1e6 .* [0.11, 0.12, 0.13, 0.13, 0.13, 0.13, 0.11, 0.08, 0.06]
C = let C = [1.2 * exp(-abs(i - j) / 1.5) + 0.35 + (i <= 2 && j <= 2 ? 2.0 : 0.0) for i in 1:G, j in 1:G]
    (C .+ C') ./ 2
end
susc = [0.5, 0.7, 1.0, 1.0, 1.0, 1.0, 1.1, 1.2, 1.3]
I0 = [i == 3 ? 10.0 : 0.0 for i in 1:G]
(groups = G, population = sum(N), contacts_per_day = round.(sum(C; dims = 2)[:]; digits = 1))

#%% code id=contacts_plot
let fig = Figure(size = (520, 420)), ax = Axis(fig[1, 1]; title = "contacts per day", xticks = (1:G, ages),
                                               yticks = (1:G, ages), xticklabelrotation = π / 4, aspect = 1)
    hm = heatmap!(ax, C; colormap = :magma)
    Colorbar(fig[1, 2], hm)
    fig
end

#%% md id=data_md
@md"""
## The reports

Twenty weeks of daily reported cases: new infections, delayed by a few days on their way to being
reported, times the reporting share, with counting noise on top.
"""

#%% code id=data
days = 140
observed = let β = 0.06, σ = 1 / 4, γ = 1 / 6, ρ = 0.3, dt = 0.02, rng = Xoshiro(7)
    S, E, I = N .- I0, zeros(G), copy(I0)
    infected = Float64[]
    for d in 1:days
        S0 = sum(S)
        for _ in 1:round(Int, 1 / dt)
            inf = β .* susc .* (C * (I ./ N)) .* S
            S, E, I = S .- dt .* inf, E .+ dt .* (inf .- σ .* E), I .+ dt .* (σ .* E .- γ .* I)
        end
        push!(infected, S0 - sum(S))
    end
    a, θ = (5.0 / 2.5)^2, 2.5^2 / 5.0                       # delay: mean 5 days, sd 2.5
    kern = [k^(a - 1) * exp(-k / θ) for k in 1:21]; kern ./= sum(kern)
    [max(0.0, round(ρ * c + sqrt(ρ * c + 1) * randn(rng)))
     for c in (sum(infected[t - k + 1] * kern[k] for k in 1:min(21, t)) for t in 1:days)]
end
(days = length(observed), peak_day = argmax(observed), peak = maximum(observed), total = sum(observed))

#%% md id=sim_md
@md"""
## The simulation

Fourth-order Runge-Kutta on the nine age bands, in place: the state is one `G × 4` matrix, the
right-hand side writes into a buffer it is handed, and the force of infection is a matrix-vector
product of the contacts with the infectious, done by `mul!`. It returns each day's new infections.
"""

#%% code id=sim
struct Params{T<:Real,V<:AbstractVector{T}}
    β::T      # transmission rate per contact
    σ::T      # 1 / incubation period
    γ::T      # 1 / infectious period
    ρ::T      # share of infections reported
    susc::V   # relative susceptibility by age
end

# Scratch space for one simulation: the force of infection, and the four RK stages.
struct Work{T}
    x::Vector{T}
    λ::Vector{T}
    k::NTuple{4,Matrix{T}}
end
Work(G) = Work(zeros(G), zeros(G), ntuple(_ -> zeros(G, 4), 4))

# u is G × 4: S, E, I, R by age band. du is written in place.
function rhs!(du, u, p, C, N, w)
    G = size(u, 1)
    @inbounds for g in 1:G
        w.x[g] = u[g, 3] / N[g]
    end
    mul!(w.λ, C, w.x)
    @inbounds for g in 1:G
        inf = p.β * p.susc[g] * w.λ[g] * u[g, 1]
        du[g, 1] = -inf
        du[g, 2] = inf - p.σ * u[g, 2]
        du[g, 3] = p.σ * u[g, 2] - p.γ * u[g, 3]
        du[g, 4] = p.γ * u[g, 3]
    end
    du
end

function infections!(out, u0, p, C, N, w; dt = 0.2)
    u = copy(u0); tmp = similar(u)
    k1, k2, k3, k4 = w.k
    for d in eachindex(out)
        S0 = sum(@view u[:, 1])
        for _ in 1:round(Int, 1 / dt)
            rhs!(k1, u, p, C, N, w)
            @. tmp = u + dt / 2 * k1; rhs!(k2, tmp, p, C, N, w)
            @. tmp = u + dt / 2 * k2; rhs!(k3, tmp, p, C, N, w)
            @. tmp = u + dt * k3;     rhs!(k4, tmp, p, C, N, w)
            @. u += dt / 6 * (k1 + 2k2 + 2k3 + k4)
        end
        out[d] = S0 - sum(@view u[:, 1])
    end
    out
end

# Poisson negative log-likelihood of the reports, its constant term dropped.
function poisson_nll(expected::Vector{Float64}, observed::Vector{Float64})
    s = 0.0
    for t in eachindex(expected, observed)
        λ = max(expected[t], 1e-9)
        s += λ - observed[t] * log(λ)
    end
    s
end

#%% md id=draft_md
@md"""
## The reporting delay, first draft

The delay settings come from a config dictionary, the way settings usually arrive. Each day's
expected reports are the infections of the last three weeks weighted by the delay distribution.
The calibration draws random parameters and keeps the best, with a closure doing each trial.
"""

#%% code id=obs_v1
obs_config = Dict{Symbol,Any}(:delay_mean => 5.0, :delay_sd => 2.5, :max_delay => 21)

# The delay as weights for 1, 2, … days: a discretised gamma with the configured mean and sd.
function delay_kernel(cfg)
    m, s, K = cfg[:delay_mean], cfg[:delay_sd], cfg[:max_delay]
    a, θ = (m / s)^2, s^2 / m
    w = [k^(a - 1) * exp(-k / θ) for k in 1:K]
    w ./ sum(w)
end

function expected_reports(infected, ρ, cfg)
    out = []
    for t in eachindex(infected)
        kern = delay_kernel(cfg)
        window = infected[max(1, t - length(kern) + 1):t]
        w = reverse(kern)[end-length(window)+1:end]
        push!(out, ρ * sum(window .* w))
    end
    out
end

function calibrate(observed, C, N, I0; n = 10_000, seed = 1)
    rng = Xoshiro(seed)
    G = length(N)
    u0 = hcat(N .- I0, zeros(G), I0, zeros(G))
    w = Work(G)
    infected = zeros(length(observed))
    best = Inf
    bestp = nothing
    trial = () -> begin
        p = Params(0.02 + 0.06rand(rng), 1 / (2 + 6rand(rng)), 1 / (3 + 9rand(rng)), 0.1 + 0.8rand(rng), susc)
        infections!(infected, u0, p, C, N, w)
        l = poisson_nll(Float64.(expected_reports(infected, p.ρ, obs_config)), observed)
        if l < best
            best = l
            bestp = p
        end
    end
    foreach(_ -> trial(), 1:n)
    bestp, best
end

#%% code id=fit_v1
fit_draft = calibrate(observed, C, N, I0)

#%% md id=profile_md
@md"""
## Where does the time go?

Open the profiler on `fit_v1` and press **▶ Run and profile**. The cell runs as it always does,
under the sampler.

Under `calibrate`, the flame graph splits in two, side by side and about the same width:

- **`infections!`, the simulation.** Its bars carry no marks. Underneath are the in-place broadcasts
  of the RK stages, the right-hand side's arithmetic, and `mul!` in LinearAlgebra's colour: the
  matrix product, every evaluation. This is the model's real cost.
- **`expected_reports`, the reporting delay.** It does a few thousand multiplications per trial,
  next to the simulation's few hundred thousand, and takes as long. Its bars carry **⤳** (runtime
  dispatch) and **♻** (garbage collection), and under it are `delay_kernel`, slices, `reverse` and
  the allocator.

Switch the colour key to **time**: the bars that spend time themselves light up, and the
observation model's are as hot as the simulation's.

So half the time is waste, beside work that has to happen. The profile shows where; it does not
show why. Add JET (the **＋ JET** button in the header, if it is not there yet) and press
**Compile**. JET analyses the cell without running it. Its findings land on the lines in the
margin, with what each one means when you hover it, and in **Details**:

| line | finding | cause |
|---|---|---|
| `a, θ = …` and `w = [k^(a - 1) …]` in `delay_kernel` | runtime dispatch | `m`, `s` and `K` come out of a `Dict{Symbol,Any}`: their types are unknown, and so is everything computed from them |
| the trial's `p = Params(…, susc)`, `infections!(…)` and `expected_reports(…, obs_config)` | runtime dispatch | `susc` and `obs_config` are notebook globals, and a function that reads a non-constant global cannot know its type |
| `best = Inf` and `if l < best` in `calibrate` | boxed capture, and the dispatch it causes | `trial` reassigns `best` and `bestp`, so both live in a heap box |
| one line of `rhs!`, in the simulation | runtime dispatch | caused by its caller: the global `susc` reaches it inside `p`. It goes when the caller is fixed |

The last row is worth a second look. JET marks where a type is used, and the cause can be several
calls away; the hover card on a line says where the unknown value came from.

The profile also says something JET does not: `delay_kernel` is rebuilt for every day of every
trial, though it never changes.
"""

#%% md id=tuned_md
@md"""
## The reporting delay, tuned

- **Typed settings, read once.** The delay is a `Delay` holding its weights, built from the
  config before the search starts, with the config's values asserted to the types they are.
- **No allocation per day.** The convolution is a plain loop into a vector it is handed.
- **Inputs as arguments.** The search is handed `susc` and the delay instead of reading notebook
  globals, so their types are known inside it.
- **A plain loop for the search.** `best` and `bestp` are ordinary locals.
"""

#%% code id=obs_v2
struct Delay{T}
    kern::Vector{T}   # weights for 1, 2, … days
end
# The config's values are `Any` to the compiler; asserting their types here is what keeps that
# from spreading into everything the delay touches.
function Delay(cfg::AbstractDict)
    m, s, K = cfg[:delay_mean]::Float64, cfg[:delay_sd]::Float64, cfg[:max_delay]::Int
    a, θ = (m / s)^2, s^2 / m
    w = [k^(a - 1) * exp(-k / θ) for k in 1:K]
    Delay(w ./ sum(w))
end

function expected_reports!(out, infected, ρ, d::Delay)
    K = length(d.kern)
    @inbounds for t in eachindex(out, infected)
        s = 0.0
        for k in 1:min(K, t)
            s += infected[t - k + 1] * d.kern[k]
        end
        out[t] = ρ * s
    end
    out
end

function calibrate_tuned(observed, C, N, I0, susc, delay; n = 10_000, seed = 1)
    rng = Xoshiro(seed)
    G = length(N)
    u0 = hcat(N .- I0, zeros(G), I0, zeros(G))
    w = Work(G)
    infected = zeros(length(observed)); reports = similar(infected)
    best = Inf
    bestp = Params(NaN, NaN, NaN, NaN, susc)
    for _ in 1:n
        p = Params(0.02 + 0.06rand(rng), 1 / (2 + 6rand(rng)), 1 / (3 + 9rand(rng)), 0.1 + 0.8rand(rng), susc)
        infections!(infected, u0, p, C, N, w)
        l = poisson_nll(expected_reports!(reports, infected, p.ρ, delay), observed)
        if l < best
            best = l
            bestp = p
        end
    end
    bestp, best
end

#%% code id=fit_v2
fit_tuned = calibrate_tuned(observed, C, N, I0, susc, Delay(obs_config))

#%% md id=check_md
@md"""
Same seed, same draws, so the two searches must agree.
"""

#%% code id=check
let (p1, l1) = fit_draft, (p2, l2) = fit_tuned
    agree = all(isapprox.((p1.β, p1.σ, p1.γ, p1.ρ), (p2.β, p2.σ, p2.γ, p2.ρ)))
    (same_answer = agree, nll_draft = round(l1), nll_tuned = round(l2))
end

#%% md id=after_md
@md"""
## What is left

Profile `fit_v2` and compare it with the run before (**compare with…** in the header). The ⤳ and ♻
marks are gone, `expected_reports!` is a sliver, and nearly all the time is the simulation: the
matrix product, the RK stages, the right-hand side's arithmetic. **Compile** reports nothing.

That is the model's real cost, and no fix of the same kind will shrink it. Going faster from here
takes a different algorithm: fewer right-hand-side evaluations per day (a larger or adaptive step,
checked against this one), or a smarter search than random draws, which needs far fewer of them.

The fit itself recovers the transmission rate and the reporting share, while the incubation and
infectious periods trade off against each other and against the reporting delay: reported counts
alone cannot tell them apart.
"""

#%% code id=params
let fmt(p) = @sprintf("β %.3f · incubation %.1f d · infectious %.1f d · reported %.0f%%", p.β, 1 / p.σ, 1 / p.γ, 100p.ρ)
    (fitted = fmt(fit_tuned[1]), data_came_from = fmt(Params(0.06, 1 / 4, 1 / 6, 0.3, susc)))
end

#%% code id=plot
let fig = Figure(size = (900, 420)), ax = Axis(fig[1, 1]; xlabel = "day", ylabel = "reported cases")
    u0 = hcat(N .- I0, zeros(G), I0, zeros(G))
    p = fit_tuned[1]
    infected = infections!(zeros(days), u0, p, C, N, Work(G))
    lines!(ax, 1:days, expected_reports!(zeros(days), infected, p.ρ, Delay(obs_config));
           color = :deepskyblue, linewidth = 2.5, label = "fitted")
    lines!(ax, 1:days, p.ρ .* infected; color = (:deepskyblue, 0.45), linestyle = :dash, linewidth = 1.5,
           label = "fitted, without the delay")
    scatter!(ax, 1:days, observed; color = (:white, 0.7), markersize = 6, label = "reported")
    axislegend(ax; position = :lt)
    fig
end

#%% md id=recap
@md"""
## The loop

1. **Profile** the cell that is slow. The flame graph and hot lines say where the time goes; the
   ⤳, ♻ and ⚙ marks say what kind of time it is, and the **time** colouring shows which bars spend it.
2. **Compile** with JET in the environment. Its findings say why, on the lines they come from,
   without running anything.
3. **Fix the findings on hot lines**, and leave the rest. Compile again to see a finding go.
4. **Profile again** and compare with the run before. When what is left is real work, the next
   step is a better algorithm, not a fix.

The profiling specialist (**＋ specialist**) works the same loop beside you in the profiler, and
asks before it changes a cell.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 34a383e6-83ac-436c-987d-e975d217ec91
#   format = 2
# ╚═╡
