#%% code id=setup
using Random
"ready"

#%% md id=title
# ⚡ Async reactivity — live data acquisition

Click **Run acquisition**: the `acquire` cell spawns an `@async` loop that records
samples into `data` and calls **`slate_refresh(:data)`** each tick. The server
recomputes the cells that *read* `data` (the chart + status) and pushes a live,
in-place update — the UI stays responsive the whole time. Changing the **rate**
(or clicking again) cancels the running loop and starts a fresh one.

#%% code id=controls
@bind go Button("Run acquisition")
@bind rate Slider(0.01:0.01:1.0)

#%% code id=acquire controls=[go,rate]
go                                              # depend on the button → click (re)starts
global data = Float64[]
global acqgen = (@isdefined(acqgen) ? acqgen : 0) + 1
let g = acqgen, dt = rate
    @async for i in 1:1000
        g == acqgen || break                    # a newer run started → stop this one
        push!(data, sin(i / 15) + 0.25 * randn())
        slate_refresh(:data)                     # readers of `data` recompute + live-push
        sleep(dt)
    end
end
"run #$go — sampling every $(rate)s"

#%% code id=chart controls=rate
echart(Dict(
    "title" => Dict("text" => "Live signal"),
    "tooltip" => Dict("trigger" => "axis"),
    "animationDuration" => 120,
    "xAxis" => Dict("type" => "category", "data" => collect(1:length(data))),
    "yAxis" => Dict("type" => "value", "min" => -2, "max" => 2),
    "series" => [Dict("type" => "line", "showSymbol" => false, "data" => round.(data; digits = 3),
                      "lineStyle" => Dict("color" => "#3aa0ff", "width" => 2),
                      "areaStyle" => Dict("opacity" => 0.12))],
))

#%% code id=3c88cc

#%% code id=status
(; samples = length(data),
   latest = isempty(data) ? nothing : round(data[end]; digits = 3),
   mean = isempty(data) ? nothing : round(sum(data) / length(data); digits = 3))
