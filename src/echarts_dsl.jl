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
# Ergonomic kinds — line, bar, scatter, area, pie, heatmap, candlestick, radar, boxplot —
# know their data shape AND the components they imply (a heatmap brings category axes + a
# visualMap; radar brings the radar component; …). Any OTHER series type works via
# `series(:kind, …; data=…)`, and every extra kwarg / top-level component (grid, dataZoom,
# toolbox, markLine, …) passes through verbatim — the DSL never gates ECharts.

# Recursively ECharts-ify a DSL value: Symbol→String, NamedTuple/Dict→Dict, Tuple→vector;
# numeric/string vectors pass straight through (no needless copy).
_ec(v::Symbol) = String(v)
_ec(v::NamedTuple) = Dict{String,Any}(String(k) => _ec(getfield(v, k)) for k in keys(v))
_ec(v::AbstractDict) = Dict{String,Any}(String(k) => _ec(x) for (k, x) in v)
_ec(v::Tuple) = Any[_ec(x) for x in v]
_ec(v::AbstractVector) = eltype(v) <: Union{Number,AbstractString} ? v : Any[_ec(x) for x in v]
_ec(v) = v

# A single series plus the top-level COMPONENTS it implies (xAxis/yAxis/visualMap/radar/…).
# `echart` merges these into the option (first series wins per key; user kwargs override).
struct EChartSeries
    opt::Dict{String,Any}
    kind::String
    layout::Dict{String,Any}
end

_iscat(x) = !isempty(x) && all(e -> e isa AbstractString || e isa Symbol, x)
_str(s) = s isa Symbol ? String(s) : s
_cataxis(xs) = Dict{String,Any}("type" => "category", "data" => collect(xs))

# Type-7 (linear-interpolation) five-number summary for a boxplot category — Base only.
function _q5(v)
    s = sort!(collect(Float64, v)); n = length(s)
    q(p) = (h = (n - 1) * p + 1; lo = floor(Int, h); hi = min(ceil(Int, h), n); s[lo] + (h - lo) * (s[hi] - s[lo]))
    [s[1], q(0.25), q(0.5), q(0.75), s[n]]
end

# z::Matrix (rows = y, cols = x) → ECharts `[xIndex, yIndex, value]` triples + category axes +
# a calculable visualMap spanning the data. `series(:heatmap, z)` or `series(:heatmap, xs, ys, z)`.
function _heatmap!(opt, layout, args)
    if length(args) == 1 && args[1] isa AbstractMatrix
        z = args[1]; xs = string.(1:size(z, 2)); ys = string.(1:size(z, 1))
    elseif length(args) == 3 && args[3] isa AbstractMatrix
        z = args[3]; xs = string.(collect(args[1])); ys = string.(collect(args[2]))
    else
        return
    end
    nr, nc = size(z)
    opt["data"] = [[j - 1, i - 1, z[i, j]] for i in 1:nr for j in 1:nc]
    lo, hi = extrema(z)
    layout["xAxis"] = _cataxis(xs)
    layout["yAxis"] = _cataxis(ys)
    layout["visualMap"] = Dict{String,Any}("min" => lo, "max" => hi, "calculable" => true,
                                            "orient" => "horizontal", "left" => "center", "bottom" => 0)
end

# indicators: `name => max` pairs (or raw dicts/NamedTuples); vals: one value vector, or
# `name => vector` pairs for several rings. `series(:radar, indicators, vals)`.
function _radar!(opt, layout, indicators, vals)
    layout["radar"] = Dict{String,Any}("indicator" =>
        Any[i isa Pair ? Dict{String,Any}("name" => string(i.first), "max" => i.second) : _ec(i) for i in indicators])
    opt["data"] = (vals isa AbstractVector && !isempty(vals) && first(vals) isa Pair) ?
        Any[Dict{String,Any}("name" => string(p.first), "value" => collect(p.second)) for p in vals] :
        Any[Dict{String,Any}("value" => collect(vals))]
end

"""
    series(kind, args...; name=nothing, kwargs...)

Build one series for [`echart`](@ref). `kind` is an ECharts series type:

- `:line` / `:bar` / `:area` `(x, y)` — string x → category axis, numeric x → value axis
- `:scatter` `(x, y)`
- `:pie` `(labels, values)`
- `:heatmap` `(z::Matrix)` or `(xlabels, ylabels, z)` — adds category axes + a visualMap
- `:candlestick` `(dates, ohlc)` — `ohlc[i] = [open, close, low, high]`
- `:radar` `(indicators, values)` — `indicators = ["Sales" => 6500, …]`; values a vector, or
  `["Allocated" => […], "Actual" => […]]` for several rings
- `:boxplot` `(categories, data)` — each `data[i]` is `[min,Q1,med,Q3,max]` or raw samples

Any other `kind` falls back to `data = args[1]`. Extra kwargs (`smooth`, `stack`,
`symbolSize`, `areaStyle`, `markLine`, …) splice into the series option verbatim.
"""
function series(kind::Symbol, args...; name = nothing, kwargs...)
    k = String(kind)
    isarea = k == "area"
    isarea && (k = "line")
    opt = Dict{String,Any}("type" => k)
    layout = Dict{String,Any}()
    isarea && (opt["areaStyle"] = Dict{String,Any}())
    name === nothing || (opt["name"] = _str(name))
    if k in ("line", "bar") && length(args) == 2
        x, y = args
        if _iscat(x)
            layout["xAxis"] = _cataxis(x); opt["data"] = collect(y)
        else
            opt["data"] = [[x[i], y[i]] for i in eachindex(x, y)]
        end
    elseif k == "scatter" && length(args) == 2
        x, y = args
        opt["data"] = [[x[i], y[i]] for i in eachindex(x, y)]
    elseif k == "pie" && length(args) == 2
        labels, vals = args
        opt["data"] = [Dict{String,Any}("name" => string(labels[i]), "value" => vals[i]) for i in eachindex(labels, vals)]
    elseif k == "heatmap"
        _heatmap!(opt, layout, args)
    elseif k == "candlestick" && length(args) == 2
        dates, ohlc = args
        opt["data"] = [collect(r) for r in ohlc]
        layout["xAxis"] = _cataxis(dates)
        layout["yAxis"] = Dict{String,Any}("type" => "value", "scale" => true)
    elseif k == "radar" && length(args) == 2
        _radar!(opt, layout, args[1], args[2])
    elseif k == "boxplot" && length(args) == 2
        cats, data = args
        opt["data"] = [length(d) == 5 ? collect(Float64, d) : _q5(d) for d in data]
        layout["xAxis"] = _cataxis(cats)
        layout["yAxis"] = Dict{String,Any}("type" => "value")
    elseif length(args) == 1
        opt["data"] = _ec(only(args))
    elseif length(args) >= 2 && args[1] isa AbstractVector && args[2] isa AbstractVector
        x, y = args[1], args[2]
        opt["data"] = [[x[i], y[i]] for i in eachindex(x, y)]
    end
    for (kk, vv) in kwargs
        opt[String(kk)] = _ec(vv)
    end
    return EChartSeries(opt, k, layout)
end

# Series kinds that carry no cartesian x/y axis (they bring their own coordinate system).
const _EC_NOAXIS = Set(["pie", "radar", "gauge", "funnel", "sunburst", "tree", "treemap", "sankey", "graph", "map"])

# Assemble the full option from series + layout. Each series' implied components are merged
# first (first wins per key), then cartesian kinds get default value axes if none was implied;
# unknown kwargs (grid/dataZoom/toolbox/color/animation/…) pass through raw and override.
function _echart_build(slist; title = nothing, legend = nothing, tooltip = true, theme = true, kwargs...)
    opt = Dict{String,Any}("series" => [s.opt for s in slist])
    theme === false || (opt["backgroundColor"] = "transparent")
    # Reactive charts re-`setOption` on every update; ECharts' ~1s default UPDATE animation lags
    # behind rapid streams (the needle chases a stale value). Default to a snappier transition that
    # tracks typical reactive cadences; override via a kwarg (e.g. `animation = false` to snap).
    opt["animationDurationUpdate"] = 300
    if title !== nothing
        opt["title"] = (title isa AbstractString || title isa Symbol) ? Dict{String,Any}("text" => String(title)) : _ec(title)
    end
    for s in slist, (k, v) in s.layout
        haskey(opt, k) || (opt[k] = v)
    end
    noaxis = !isempty(slist) && all(s -> s.kind in _EC_NOAXIS, slist)
    if !noaxis
        haskey(opt, "xAxis") || (opt["xAxis"] = Dict{String,Any}("type" => "value"))
        haskey(opt, "yAxis") || (opt["yAxis"] = Dict{String,Any}("type" => "value"))
    end
    if tooltip === true
        opt["tooltip"] = Dict{String,Any}("trigger" => noaxis ? "item" : "axis")
    elseif tooltip !== false
        opt["tooltip"] = _ec(tooltip)
    end
    # Legend. An explicit `legend=<spec>` is the caller's to position — left untouched. An AUTO legend
    # (legend=true, or several named series) is an empty dict ECharts fills from the series names; that
    # and a title both default to the top row, so a wide title overlaps the centered legend. When both
    # are present, drop the auto legend to its own row beneath the title and reserve plotting space
    # below it (cartesian only — pie/radar ignore `grid`; a series- or caller-supplied grid wins).
    if legend === false
        # no legend
    elseif legend !== true && legend !== nothing
        opt["legend"] = _ec(legend)
    elseif legend === true || count(s -> haskey(s.opt, "name"), slist) > 1
        leg = Dict{String,Any}()
        if haskey(opt, "title")
            leg["top"] = 30
            (noaxis || haskey(opt, "grid")) || (opt["grid"] = Dict{String,Any}("top" => 72, "containLabel" => true))
        end
        opt["legend"] = leg
    end
    for (k, v) in kwargs
        opt[String(k)] = _ec(v)
    end
    return opt
end

"""
    echart(kind::Symbol, args...; title, legend, tooltip, theme, kwargs...)  # Express: one series
    echart(series(…), series(…); title, legend, …)                          # Composable: many series
    echart(; xAxis=…, series=[…])                                           # Raw NamedTuple/dict options

Build an [Apache ECharts](https://echarts.apache.org) chart that renders live in the cell,
animating **in place** on reactive updates. Three layers, all sugar over the raw option dict —
nothing in ECharts is out of reach. RETURN one from a cell to display it. (This is Slate's own
helper — not Makie's `series`, not a package; see also [`series`](@ref).)

# Express — one series; axes inferred (string x → category, numeric x → value)
```julia
echart(:line, ["Mon", "Tue", "Wed"], [120, 200, 150]; title = "Visits", smooth = true)
echart(:bar, days, counts);  echart(:scatter, randn(500), randn(500); symbolSize = 3)
echart(:pie, ["A", "B", "C"], [10, 20, 30])
```

# Ergonomic kinds — know their data shape AND bring the components they imply
`:heatmap` (matrix → category axes + visualMap), `:candlestick` (OHLC), `:radar` (indicators),
`:boxplot` (raw samples → 5-number summary):
```julia
echart(:heatmap, xlabels, ylabels, z)                       # z::Matrix (rows = y, cols = x)
echart(:radar, ["Sales" => 6500, "Tech" => 30000], [4200, 20000])
```

# Composable — several series via `series(kind, …; name=…)`
```julia
echart(series(:line, x, sin.(x); name = "sin"),
       series(:bar,  x, counts;   name = "n"); legend = true, title = "Mix")
```

# Raw — the full ECharts surface (Symbol/NamedTuple-friendly)
```julia
echart(; xAxis = (type = :category, data = days), yAxis = (type = :value,),
         series = [(type = :bar, data = counts)], dataZoom = [(type = :slider,)])
```

Dark theme + tooltip default on; a legend appears when several series are named; extra kwargs and
top-level components (`grid`, `dataZoom`, `visualMap`, `markLine`, …) pass through verbatim. Pairs
with `@bind` (read a control in the cell → it recomputes) and `reactive`/`@onclick` (stream updates
into a live value) — see the `slate.api` reference.
"""
# Express: a single series + simple layout (title/legend/tooltip/theme); ALL OTHER kwargs → the series.
echart(kind::Symbol, args...; title = nothing, legend = nothing, tooltip = true, theme = true, kwargs...) =
    EChart(_echart_build([series(kind, args...; kwargs...)]; title = title, legend = legend, tooltip = tooltip, theme = theme))
# Composable: one or more `series(...)`, plus raw layout/components (grid/dataZoom/visualMap/…).
echart(s::EChartSeries, more::EChartSeries...; kwargs...) = EChart(_echart_build([s, more...]; kwargs...))
# Raw NamedTuple/keyword options — the full ECharts surface, Symbol/NamedTuple-friendly.
echart(; kwargs...) = EChart(Dict{String,Any}(String(k) => _ec(v) for (k, v) in kwargs))
