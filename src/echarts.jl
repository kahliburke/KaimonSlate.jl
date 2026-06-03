# Interactive charts via ECharts (interactivity Layer 2). Included into
# `module ReportEngine`.
#
# A cell returns `echart(option)`. It is captured as an ECharts spec (JSON) and
# rendered in the browser as a live, interactive chart (zoom / pan / hover). On
# reactive recompute (edit or widget drag) the browser calls `chart.setOption`
# on the existing instance — a smooth in-place update, no image swap.
import JSON

struct EChart
    option::Dict{String,Any}
end

"Build an interactive ECharts chart from an option dict."
echart(option::AbstractDict) = EChart(Dict{String,Any}(string(k) => v for (k, v) in option))

Base.showable(::MIME"application/x-echarts", ::EChart) = true
Base.show(io::IO, ::MIME"application/x-echarts", c::EChart) = JSON.print(io, c.option)

export EChart, echart
