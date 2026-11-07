try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Where the time goes

The same sum written two ways: one with an untyped accumulator, one typed.
"""

#%% code id=version
@bind version Select(["slow", "fast"], "slow"; label = "version")

#%% code id=defs
function energy_slow(xs)
    total = 0          # starts as an Int, becomes a Float64
    parts = []         # a Vector{Any}
    for i in eachindex(xs), j in (i + 1):length(xs)
        d = abs(xs[i] - xs[j])
        push!(parts, 1 / (d + 0.1))
        total += parts[end]
    end
    return total
end

function energy_fast(xs)
    total = 0.0
    for i in eachindex(xs), j in (i + 1):length(xs)
        total += 1 / (abs(xs[i] - xs[j]) + 0.1)
    end
    return total
end

#%% code id=hot
xs = sin.(1:6000) .* 10
energy = version == "slow" ? energy_slow(xs) : energy_fast(xs)

#%% code id=spread
# Uneven pieces of work, one per thread, so the threads finish at different times.
sizes = [6000, 9000, 12000, 15000]
parts = zeros(length(sizes))
Threads.@threads for t in eachindex(sizes)
    parts[t] = energy_fast(sin.(1:sizes[t]))
end
sum(parts)

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 96ceaa3f-ac67-4fa7-937f-26f3e2725823
#   format = 2
# ╚═╡
