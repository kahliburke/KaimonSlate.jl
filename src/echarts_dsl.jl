# ── ECharts DSL (interactivity Layer 2) ───────────────────────────────────────
# A thin, Julian surface over the raw ECharts option dict. Shared by the engine
# (ReportEngine) and the standalone worker (SlateWorker) — each defines `EChart` +
# `echart(::AbstractDict)` first, then includes this to ADD the DSL methods. Base-only
# (no deps) so it loads into any worker env. Everything is sugar over the dict and the
# raw option is always reachable, so the ENTIRE ECharts surface stays available:
#
#   echart(:line, days, sales; title="Sales", smooth=true)          # Express: one series
#   echart(series(:line, x, sin.(x); name="sin"),                   # composable: many series
#          series(:bar,  x, counts;  name="n"); title="Mix", legend=true)
#   echart(; xAxis=(type=:category, data=days), series=[...])       # raw NamedTuple options
#   echart(Dict("series" => [...]))                                 # raw dict (legacy, unchanged)
#
# Tier 1 (ergonomic): line, bar, scatter, area, pie. Any other series type works via
# `series(:kind, …; data=…)` and every extra kwarg / top-level component (grid, dataZoom,
# visualMap, toolbox, markLine, …) passes through verbatim — the DSL never gates ECharts.

# Recursively ECharts-ify a DSL value: Symbol→String, NamedTuple/Dict→Dict, Tuple→vector;
# numeric/string vectors pass straight through (no needless copy).
_ec(v::Symbol) = String(v)
_ec(v::NamedTuple) = Dict{String,Any}(String(k) => _ec(getfield(v, k)) for k in keys(v))
_ec(v::AbstractDict) = Dict{String,Any}(String(k) => _ec(x) for (k, x) in v)
_ec(v::Tuple) = Any[_ec(x) for x in v]
_ec(v::AbstractVector) = eltype(v) <: Union{Number,AbstractString} ? v : Any[_ec(x) for x in v]
_ec(v) = v

# A single series + the category x-axis it implies (`nothing` → value axis, or no axis).
struct EChartSeries
    opt::Dict{String,Any}
    xcat::Any
    kind::String
end

_iscat(x) = !isempty(x) && all(e -> e isa AbstractString || e isa Symbol, x)
_str(s) = s isa Symbol ? String(s) : s

"""
    series(kind, args...; name=nothing, kwargs...)

Build one series for [`echart`](@ref). `kind` is an ECharts series type — `:line`,
`:bar`, `:scatter`, `:area`, `:pie`, or any other (e.g. `:radar`, `:sankey`). Data
positionals depend on the kind: `x, y` for line/bar/scatter/area; `labels, values`
for pie; a single `data` arg otherwise. Any extra kwargs (`smooth`, `stack`,
`symbolSize`, `areaStyle`, `markLine`, …) splice into the series option verbatim.
"""
function series(kind::Symbol, args...; name = nothing, kwargs...)
    k = String(kind)
    isarea = k == "area"
    isarea && (k = "line")
    opt = Dict{String,Any}("type" => k)
    isarea && (opt["areaStyle"] = Dict{String,Any}())
    name === nothing || (opt["name"] = _str(name))
    xcat = nothing
    if k in ("line", "bar") && length(args) == 2
        x, y = args
        if _iscat(x)
            xcat = collect(x); opt["data"] = collect(y)
        else
            opt["data"] = [[x[i], y[i]] for i in eachindex(x, y)]
        end
    elseif k == "scatter" && length(args) == 2
        x, y = args
        opt["data"] = [[x[i], y[i]] for i in eachindex(x, y)]
    elseif k == "pie" && length(args) == 2
        labels, vals = args
        opt["data"] = [Dict{String,Any}("name" => string(labels[i]), "value" => vals[i]) for i in eachindex(labels, vals)]
    elseif length(args) == 1
        opt["data"] = _ec(only(args))
    elseif length(args) >= 2 && args[1] isa AbstractVector && args[2] isa AbstractVector
        x, y = args[1], args[2]
        opt["data"] = [[x[i], y[i]] for i in eachindex(x, y)]
    end
    for (kk, vv) in kwargs
        opt[String(kk)] = _ec(vv)
    end
    return EChartSeries(opt, xcat, k)
end

# Series kinds that carry no cartesian x/y axis.
const _EC_NOAXIS = Set(["pie", "radar", "gauge", "funnel", "sunburst", "tree", "treemap", "sankey", "graph", "map"])

# Assemble the full option from series + layout. Axes are added for cartesian kinds only;
# unknown kwargs (grid/dataZoom/visualMap/toolbox/color/animation/…) pass through raw.
function _echart_build(slist; title = nothing, legend = nothing, tooltip = true, theme = true, kwargs...)
    opt = Dict{String,Any}("series" => [s.opt for s in slist])
    theme === false || (opt["backgroundColor"] = "transparent")
    if title !== nothing
        opt["title"] = (title isa AbstractString || title isa Symbol) ? Dict{String,Any}("text" => String(title)) : _ec(title)
    end
    noaxis = !isempty(slist) && all(s -> s.kind in _EC_NOAXIS, slist)
    if !noaxis
        catx = nothing
        for s in slist
            s.xcat === nothing || (catx = s.xcat; break)
        end
        opt["xAxis"] = catx === nothing ? Dict{String,Any}("type" => "value") :
                                          Dict{String,Any}("type" => "category", "data" => catx)
        opt["yAxis"] = Dict{String,Any}("type" => "value")
    end
    if tooltip === true
        opt["tooltip"] = Dict{String,Any}("trigger" => noaxis ? "item" : "axis")
    elseif tooltip !== false
        opt["tooltip"] = _ec(tooltip)
    end
    if legend === true
        opt["legend"] = Dict{String,Any}()
    elseif legend === nothing
        count(s -> haskey(s.opt, "name"), slist) > 1 && (opt["legend"] = Dict{String,Any}())
    elseif legend !== false
        opt["legend"] = _ec(legend)
    end
    for (k, v) in kwargs
        opt[String(k)] = _ec(v)
    end
    return opt
end

# Express: a single series + simple layout (title/legend/tooltip/theme); ALL OTHER kwargs → the series.
echart(kind::Symbol, args...; title = nothing, legend = nothing, tooltip = true, theme = true, kwargs...) =
    EChart(_echart_build([series(kind, args...; kwargs...)]; title = title, legend = legend, tooltip = tooltip, theme = theme))
# Composable: one or more `series(...)`, plus raw layout/components (grid/dataZoom/visualMap/…).
echart(s::EChartSeries, more::EChartSeries...; kwargs...) = EChart(_echart_build([s, more...]; kwargs...))
# Raw NamedTuple/keyword options — the full ECharts surface, Symbol/NamedTuple-friendly.
echart(; kwargs...) = EChart(Dict{String,Any}(String(k) => _ec(v) for (k, v) in kwargs))
