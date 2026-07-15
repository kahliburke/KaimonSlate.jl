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

# Pair x and y into ECharts `[x,y]` points, with a clear error on a length mismatch instead of a
# deep `eachindex(x,y)` DimensionMismatch from inside the DSL.
function _xy(kind, x, y)
    length(x) == length(y) ||
        throw(ArgumentError("echart(:$kind, x, y): x and y must be equal length, got $(length(x)) and $(length(y))"))
    return [[x[i], y[i]] for i in eachindex(x, y)]
end

# Type-7 (linear-interpolation) five-number summary for a boxplot category — Base only.
function _q5(v)
    s = sort!(collect(Float64, v)); n = length(s)
    n == 0 && throw(ArgumentError("echart(:boxplot, …): a category has no samples (empty vector)"))
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
        throw(ArgumentError("echart(:heatmap, …) expects a Matrix or (xlabels, ylabels, Matrix)"))
    end
    isempty(z) && throw(ArgumentError("echart(:heatmap, …): empty matrix"))
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

# ── Relational / hierarchical / geo-flow / calendar data shaping ──────────────────────────────
# (source, target, value) from a 3-tuple/3-vector, or the pair sugar `src => (tgt => val)`.
function _flow3(e)
    (e isa Union{Tuple,AbstractVector} && length(e) == 3) && return (string(e[1]), string(e[2]), e[3])
    (e isa Pair && e.second isa Pair) && return (string(e.first), string(e.second.first), e.second.second)
    throw(ArgumentError("echart(:sankey, …): a link must be (source, target, value) or `src => tgt => val` — got $(repr(e))"))
end
# (source, target) from a 2-tuple/2-vector or the pair `src => tgt`.
function _edge2(e)
    e isa Pair && return (string(e.first), string(e.second))
    (e isa Union{Tuple,AbstractVector} && length(e) == 2) && return (string(e[1]), string(e[2]))
    throw(ArgumentError("echart(:graph, …): an edge must be (source, target) or `src => tgt` — got $(repr(e))"))
end
_uniqnodes(pairs) = unique!(reduce(vcat, [[a, b] for (a, b) in pairs]; init = String[]))

# sankey: `links` (auto-derive nodes) or `(nodes, links)`; each link → {source,target,value}.
function _sankey!(opt, args)
    (length(args) in (1, 2)) || throw(ArgumentError("echart(:sankey, …) expects `links` or `(nodes, links)`"))
    flows = [_flow3(e) for e in args[end]]
    names = length(args) == 2 ? [string(n) for n in args[1]] : _uniqnodes([(f[1], f[2]) for f in flows])
    opt["data"] = Any[Dict{String,Any}("name" => n) for n in names]
    opt["links"] = Any[Dict{String,Any}("source" => s, "target" => t, "value" => v) for (s, t, v) in flows]
end
# graph (network): `edges` (auto-derive nodes) or `(nodes, edges)`; force layout + roam by default.
function _graph!(opt, args)
    (length(args) in (1, 2)) || throw(ArgumentError("echart(:graph, …) expects `edges` or `(nodes, edges)`"))
    es = [_edge2(e) for e in args[end]]
    if length(args) == 2
        opt["data"] = Any[(n isa Union{AbstractString,Symbol}) ? Dict{String,Any}("name" => string(n)) : _ec(n) for n in args[1]]
    else
        opt["data"] = Any[Dict{String,Any}("name" => n) for n in _uniqnodes(es)]
    end
    opt["links"] = Any[Dict{String,Any}("source" => s, "target" => t) for (s, t) in es]
    get!(opt, "layout", "force")
    get!(opt, "roam", true)
    haskey(opt, "label") || (opt["label"] = Dict{String,Any}("show" => true))
    haskey(opt, "force") || (opt["force"] = Dict{String,Any}("repulsion" => 140, "edgeLength" => 70))
end
# treemap/sunburst: a hierarchy. `name => value` is a leaf; `name => [children…]` a branch; a
# NamedTuple/Dict node passes through (its `children` recurse). Accepts one root or a vector of roots.
_treenode(p::Pair) = p.second isa AbstractVector ?
    Dict{String,Any}("name" => string(p.first), "children" => Any[_treenode(c) for c in p.second]) :
    Dict{String,Any}("name" => string(p.first), "value" => p.second)
_treenode(x) = _ec(x)
_hier(data) = data isa Union{Pair,NamedTuple,AbstractDict} ? Any[_treenode(data)] : Any[_treenode(x) for x in data]

"""
    series(kind, args...; name=nothing, kwargs...) -> EChartSeries

Build one series for the composable `echart(series(…), series(…); …)` form — combine different
kinds and axes in a single chart. `kind` is an ECharts series type:

- `:line` / `:bar` / `:area` `(x, y)` — string x → category axis, numeric x → value axis
- `:scatter` `(x, y)`
- `:pie` `(labels, values)`
- `:heatmap` `(z::Matrix)` or `(xlabels, ylabels, z)` — adds category axes + a visualMap
- `:candlestick` `(dates, ohlc)` — `ohlc[i] = [open, close, low, high]`
- `:radar` `(indicators, values)` — `indicators = ["Sales" => 6500, …]`; values a vector, or
  `["Allocated" => […], "Actual" => […]]` for several rings
- `:boxplot` `(categories, data)` — each `data[i]` is `[min,Q1,med,Q3,max]` or raw samples
- `:sankey` `(links)` or `(nodes, links)` — flows; each link `(source, target, value)` or `src => tgt => val`
- `:graph` `(edges)` or `(nodes, edges)` — a network; each edge `(source, target)` or `src => tgt` (force layout)
- `:treemap` / `:sunburst` `(tree)` — a hierarchy: `name => value` (leaf), `name => [children…]` (branch),
  or NamedTuple/Dict nodes; pass one root or a vector of roots
- `:lines` `(from, to)` or `(flows)` — geo trajectories/flows; coords `(lon, lat)`; binds `coordinateSystem="geo"`
  (pass `geo=(map="world",…)` + `registerMap`)
- `:calendar` `(dates, values)` — a calendar heatmap; brings the calendar component + a visualMap

Any other `kind` falls back to `data = args[1]`. `name=` labels the series for the legend; every
extra kwarg (`smooth`, `stack`, `symbolSize`, `yAxisIndex`, `areaStyle`, `markLine`, `lineStyle`, …)
splices into the series option verbatim.

    echart(series(:bar,  x, a; name="obs", stack="t"),
           series(:line, x, b; name="fit", smooth=true, yAxisIndex=1); legend=true,
           yAxis=[(name="obs",), (name="fit", type=:log)])
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
            opt["data"] = _xy(k, x, y)
        end
    elseif k == "scatter" && length(args) == 2
        x, y = args
        opt["data"] = _xy(:scatter, x, y)
    elseif k == "pie" && length(args) == 2
        labels, vals = args
        length(labels) == length(vals) ||
            throw(ArgumentError("echart(:pie, labels, values): equal length required, got $(length(labels)) and $(length(vals))"))
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
    elseif k == "sankey"
        _sankey!(opt, args)
    elseif k == "graph"
        _graph!(opt, args)
    elseif k in ("treemap", "sunburst")
        length(args) == 1 || throw(ArgumentError("echart(:$k, tree) expects one hierarchical data arg"))
        opt["data"] = _hier(args[1])
    elseif k == "lines"
        # Geo flows (trajectories): each datum is a `{coords: [[lon,lat],[lon,lat]]}` segment. Defaults
        # to the geo coordinate system (pass `geo=(map="world",…)`); override coordinateSystem for cartesian.
        if length(args) == 2
            from, to = args
            length(from) == length(to) ||
                throw(ArgumentError("echart(:lines, from, to): equal length required, got $(length(from)) and $(length(to))"))
            opt["data"] = Any[Dict{String,Any}("coords" => Any[collect(from[i]), collect(to[i])]) for i in eachindex(from, to)]
        elseif length(args) == 1
            opt["data"] = Any[Dict{String,Any}("coords" => Any[collect(a), collect(b)]) for (a, b) in args[1]]
        else
            throw(ArgumentError("echart(:lines, …) expects `(from, to)` coord vectors or a list of `(ptA, ptB)` flows"))
        end
        get!(opt, "coordinateSystem", "geo")
    elseif k == "calendar"
        # Calendar heatmap: a heatmap series bound to a `calendar` coordinate system; each datum is
        # `[date, value]`. Brings the calendar component (range auto-spanned from the dates) + a visualMap.
        length(args) == 2 || throw(ArgumentError("echart(:calendar, dates, values) expects two args"))
        dates, vals = args
        length(dates) == length(vals) ||
            throw(ArgumentError("echart(:calendar, dates, values): equal length required, got $(length(dates)) and $(length(vals))"))
        ds = [string(d) for d in dates]                    # Date shows as ISO "yyyy-mm-dd" — no Dates dep needed
        opt["type"] = "heatmap"; opt["coordinateSystem"] = "calendar"
        opt["data"] = Any[Any[ds[i], vals[i]] for i in eachindex(ds, vals)]
        lo, hi = extrema(vals)
        y1, y2 = minimum(ds)[1:4], maximum(ds)[1:4]
        layout["calendar"] = Dict{String,Any}("range" => (y1 == y2 ? y1 : [y1, y2]), "cellSize" => Any["auto", 16])
        layout["visualMap"] = Dict{String,Any}("min" => lo, "max" => hi, "calculable" => true,
                                                "orient" => "horizontal", "left" => "center", "bottom" => 0)
        k = "heatmap"                                       # the actual ECharts series type (calendar is the coord system)
    elseif k in ("line", "bar", "scatter", "pie", "candlestick", "radar", "boxplot")
        # A known ergonomic kind matched on `k` above but not on arg count — don't silently fall
        # through to the generic branches below (which would misinterpret the args as raw data).
        throw(ArgumentError("echart(:$k, …) expects 2 positional args (see `series` docstring for the shape), got $(length(args))"))
    elseif length(args) == 1
        opt["data"] = _ec(only(args))
    elseif length(args) >= 2 && args[1] isa AbstractVector && args[2] isa AbstractVector
        opt["data"] = _xy(kind, args[1], args[2])
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
    # A series wants no cartesian axes if its KIND brings its own coordinate system (pie/sankey/graph/
    # treemap/…) OR it's bound to a non-cartesian coordinateSystem (geo/calendar/polar/…) — so geo `lines`
    # and calendar heatmaps don't get empty value axes drawn over their map/calendar.
    _nocart(s) = s.kind in _EC_NOAXIS ||
                 get(s.opt, "coordinateSystem", "") in ("geo", "calendar", "polar", "singleAxis", "parallel")
    noaxis = !isempty(slist) && all(_nocart, slist)
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
    # Consistent typography: default ALL chart text to inherit the surrounding document font (the
    # notebook's sans in the browser; the serif body in a PDF/Typst export). Without an explicit
    # family ECharts uses its own default, and a glyph that font lacks — e.g. a Unicode superscript
    # `10¹⁹` in a title — silently falls back to a DIFFERENT font, so the title diverges from the
    # rest of the chart. A caller `textStyle` kwarg overrides this.
    haskey(opt, "textStyle") || (opt["textStyle"] = Dict{String,Any}("fontFamily" => "inherit"))
    return _slate_normalize!(opt)
end

# Final Slate-side normalisation of a finished option, applied to EVERY echart form (incl. raw):
# 1. Geo-bound and heatmap series default to `progressive = 0`. ECharts progressively renders any
#    series past ~3k points onto its own layer, and that layer keeps a STALE blit when the
#    coordinate system relays out — most visibly a `geo` roam, where the dots stop following the
#    map ("zoom disconnected from the scatter"). Pass an explicit `progressive = N` to opt back in.
# 2. Top-level `height`/`width` become `__size` — a Slate front-end directive (the chart div is
#    sized before init/resize), NOT an ECharts option key, so it's split out and stripped client-side.
function _slate_normalize!(opt::Dict{String,Any})
    s = get(opt, "series", nothing)
    if s isa AbstractVector
        for e in s
            e isa AbstractDict || continue
            fragile = get(e, "coordinateSystem", "") == "geo" || get(e, "type", "") == "heatmap"
            fragile && !haskey(e, "progressive") && (e["progressive"] = 0)
        end
    end
    sz = Dict{String,Any}()
    for k in ("height", "width")
        haskey(opt, k) && (sz[k] = pop!(opt, k))
    end
    isempty(sz) || (opt["__size"] = sz)
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

# Axis / grid / zoom config in Express mode — top-level component kwargs go on the OPTION, not the
# series, so a **log axis** (or category axis, slider zoom, custom grid) works on a one-series chart:
```julia
echart(:line, x, y; yAxis = (type = :log,), title = "log-y")   # log-scaled Y axis
echart(:line, x, y; yAxis = (type = :log, min = 1), grid = (left = 60,), dataZoom = [(type = :slider,)])
```
Recognised top-level kwargs: `xAxis yAxis grid dataZoom visualMap toolbox polar angleAxis radiusAxis
radar geo dataset calendar timeline singleAxis parallel parallelAxis brush graphic axisPointer`.
Everything else (`smooth`, `symbolSize`, `stack`, `areaStyle`, `markLine`, …) styles the series.

# Ergonomic kinds — know their data shape AND bring the components they imply
`:heatmap` (matrix → category axes + visualMap), `:candlestick` (OHLC), `:radar` (indicators),
`:boxplot` (raw samples → 5-number summary):
```julia
echart(:heatmap, xlabels, ylabels, z)                       # z::Matrix (rows = y, cols = x)
echart(:radar, ["Sales" => 6500, "Tech" => 30000], [4200, 20000])
```

# Relational, hierarchical, geo-flow, and calendar kinds — nodes/links & hierarchies inferred
```julia
echart(:sankey, [("coal", "grid", 40), ("solar", "grid", 25), ("grid", "homes", 65)])   # flows
echart(:graph,  ["a", "b", "c"], [("a", "b"), "b" => "c"]; title = "Network")            # force graph
echart(:treemap, ["Eng" => ["api" => 12, "ui" => 8], "Ops" => 5])                        # hierarchy
echart(:lines, from, to; geo = (map = "world", roam = true),                             # geo trajectories
       registerMap = (name = "world", url = "/assets/maps/world.json"), effect = (show = true,))
echart(:calendar, dates, counts; title = "Commits")                                      # calendar heatmap
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

# Series styling — any kwarg that ISN'T a top-level component styles the series
```julia
echart(:bar,  x, a; stack = "total")                                   # stacked bars
echart(:line, x, y; smooth = true, symbolSize = 6, markLine = (data = [(type = :average,)],))
```
Splice-through kwargs: `smooth stack step symbolSize lineStyle itemStyle areaStyle label markLine
markPoint markArea …`. Dual Y axes: pass `yAxis = [(…,), (…, type = :log)]` and point a series at the
second with `series(:line, x, y; yAxisIndex = 1)`.

Dark theme + tooltip default on; a legend appears when several series are named; extra kwargs and
top-level components (`grid`, `dataZoom`, `visualMap`, `markLine`, …) pass through verbatim. Pairs
with `@bind` (read a control in the cell → it recomputes) and `reactive`/`@onclick` (stream updates
into a live value) — see the `slate.api` reference.
"""
# Top-level ECharts COMPONENTS — never series fields. In Express mode a bare kwarg would otherwise be
# spliced into the SERIES, so `echart(:line, x, y; yAxis=(type=:log,))` would set a bogus series field
# and quietly do nothing. These keys are lifted onto the OPTION instead, so axis/grid/zoom config
# "just works" on a one-series chart (e.g. a log axis, a category x-axis, a slider zoom).
const _EC_TOPLEVEL = Set{String}(["xAxis", "yAxis", "grid", "dataZoom", "visualMap", "polar",
    "angleAxis", "radiusAxis", "radar", "geo", "toolbox", "dataset", "brush", "calendar", "timeline",
    "singleAxis", "parallel", "parallelAxis", "graphic", "axisPointer", "textStyle", "color",
    # Slate extensions (not ECharts keys): `registerMap=(name="world", url="/assets/maps/world.json")`
    # declares a geo map to fetch + `echarts.registerMap` before render (vector for several); the
    # front-end registers each map once per page and strips the key. `height`/`width` size the chart's
    # DIV (px number or any CSS length) — split into `__size` by `_slate_normalize!`.
    "registerMap", "height", "width"])

# Express: a single series + simple layout. Kwargs naming a top-level component (xAxis/yAxis/grid/…)
# go on the OPTION (so `yAxis=(type=:log,)` makes a log axis); everything else styles the series.
function echart(kind::Symbol, args...; title = nothing, legend = nothing, tooltip = true, theme = true, kwargs...)
    serieskw = Pair{Symbol,Any}[]; topkw = Pair{Symbol,Any}[]
    for (k, v) in kwargs
        push!(String(k) in _EC_TOPLEVEL ? topkw : serieskw, k => v)
    end
    EChart(_echart_build([series(kind, args...; serieskw...)];
                         title = title, legend = legend, tooltip = tooltip, theme = theme, topkw...))
end
# Composable: one or more `series(...)`, plus raw layout/components (grid/dataZoom/visualMap/…).
echart(s::EChartSeries, more::EChartSeries...; kwargs...) = EChart(_echart_build([s, more...]; kwargs...))
# Raw NamedTuple/keyword options — the full ECharts surface, Symbol/NamedTuple-friendly.
echart(; kwargs...) = EChart(_slate_normalize!(Dict{String,Any}(String(k) => _ec(v) for (k, v) in kwargs)))
