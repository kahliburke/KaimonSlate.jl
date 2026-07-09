#%% md id=intro
# New Notebook

#%% code id=slow_base
sleep(1.0)          # deliberately over the 400 ms memo threshold
base_value = 42

#%% code id=slow_derived
sleep(0.8)
derived = base_value * 2

#%% code id=cheap_reader
cheap = derived + 1

#%% code id=deps
using LinearAlgebra

#%% code id=svd_heavy
M = [sin(i * j / 400) for i in 1:1500, j in 1:1500]
F = svd(M)
top_sv = maximum(F.S)

#%% code id=sv_chart
sleep(0.6)   # pretend the chart is expensive to build
echart(Dict(
    "xAxis" => Dict("type" => "category", "data" => collect(1:20)),
    "yAxis" => Dict("type" => "value"),
    "series" => [Dict("type" => "line", "data" => [F.S[i] for i in 1:20])],
))

#%% code id=anon_fn_heavy
anon_vals = map(x -> (sleep(0.001); x^2), 1:600)   # lambda ⇒ used to block caching entirely
anon_total = sum(anon_vals)

#%% code id=conditional_write
sleep(0.7)
if base_value > 1_000_000          # never true ⇒ `phantom` is a declared write that stays undefined
    phantom = 1
end
conditional_ok = base_value + 7
