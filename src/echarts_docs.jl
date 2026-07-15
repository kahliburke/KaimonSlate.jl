# Part of NotebookServer. A CURATED slice of the Apache ECharts option reference, mapped onto Slate's
# `echart` DSL. Slate's raw form IS the ECharts option dict, so every path here translates 1:1:
#   • a TOP-LEVEL component (xAxis/yAxis/grid/dataZoom/visualMap/legend/tooltip/title/toolbox) is a
#     kwarg on the OPTION — in Express mode too: `echart(:line, x, y; yAxis=(type=:log,))`;
#   • a `series.*` prop is a kwarg on a series — `series(:line, x, y; smooth=true)` or an Express
#     styling kwarg `echart(:line, x, y; smooth=true)`.
# Indexed under module "ECharts" into the SAME `slate_docs` search index as the Slate helpers, so
# `search_docs("logarithmic axis")` / the docs palette surface the option AND how to reach it. Curated
# (not the full auto-flattened option tree) so descriptions stay accurate and carry the DSL mapping.
# Pinned to ECharts 5.5. Add a path? Append here — `echarts_docs_version()` re-indexes on change.

"One documented ECharts option path: `path` (e.g. `yAxis.type`) and a markdown `doc` (meaning +
values/default + the Slate DSL form)."
struct EchartsDoc
    path::String
    doc::String
end

const ECHARTS_OPTION_DOCS = EchartsDoc[
    # ── Axes (xAxis / yAxis share these) ─────────────────────────────────────────────────────────
    EchartsDoc("yAxis.type", """Y-axis scale type: `"value"` (default), `"category"`, `"time"`, or
        `"log"` (logarithmic). Use `"log"` for data spanning orders of magnitude.
        Slate: `echart(:line, x, y; yAxis=(type=:log,))`."""),
    EchartsDoc("xAxis.type", """X-axis scale type: `"category"`, `"value"`, `"time"`, `"log"`. Slate
        infers it (string x ⇒ category, numeric x ⇒ value); override with
        `echart(:line, x, y; xAxis=(type=:time,))`."""),
    EchartsDoc("yAxis.logBase", """Base of the logarithm for a `type:"log"` axis (default `10`). Valid
        only when `type` is `"log"`. Slate: `yAxis=(type=:log, logBase=2)`."""),
    EchartsDoc("yAxis.name", """Axis title text, drawn beside the axis. `nameLocation`
        (`"start"|"middle"|"end"`) and `nameGap` position it. Slate: `yAxis=(name="Δ (kg)",)`."""),
    EchartsDoc("yAxis.min", """Axis lower bound: a number, `"dataMin"`, or a function. On a value axis
        the default is auto (nice round). Slate: `yAxis=(min=0,)` or `yAxis=(min="dataMin",)`."""),
    EchartsDoc("yAxis.max", """Axis upper bound: a number, `"dataMax"`, or a function. Slate:
        `yAxis=(max=100,)`."""),
    EchartsDoc("yAxis.scale", """Value axis only. `true` drops the force-to-zero baseline so the data
        range fills the axis (good for zoomed/logless comparison). Default `false`. Slate:
        `yAxis=(scale=true,)`."""),
    EchartsDoc("yAxis.inverse", """Reverse the axis direction (`true`). Default `false`. Slate:
        `yAxis=(inverse=true,)`."""),
    EchartsDoc("yAxis.position", """Where the axis sits: y-axis `"left"`/`"right"`, x-axis
        `"top"`/`"bottom"`. Enables a secondary axis on the far side. Slate: `yAxis=(position="right",)`."""),
    EchartsDoc("xAxis.boundaryGap", """Category axis: `true` (default) insets the first/last points
        (bars); `false` makes a line meet the edges. Value axis: a 2-elem pad like `["5%","5%"]`.
        Slate: `xAxis=(boundaryGap=false,)`."""),
    EchartsDoc("xAxis.data", """Category-axis tick labels (when `type:"category"`). Slate usually sets
        this for you from a string x; raw: `echart(; xAxis=(type=:category, data=days), series=[…])`."""),
    EchartsDoc("yAxis.axisLabel.formatter", """Tick-label template or function: `"{value} kg"` or a
        JS function string. Slate: `yAxis=(axisLabel=(formatter="{value}%",),)`."""),
    EchartsDoc("xAxis.axisLabel.rotate", """Rotate crowded category labels, degrees `-90..90`. Slate:
        `xAxis=(axisLabel=(rotate=45,),)`."""),
    EchartsDoc("yAxis.splitLine.show", """Toggle the horizontal grid lines at each tick (`true`/`false`).
        Slate: `yAxis=(splitLine=(show=false,),)`."""),
    EchartsDoc("yAxis.splitNumber", """Hint for how many tick intervals to draw (approximate). Slate:
        `yAxis=(splitNumber=4,)`."""),

    # ── grid (plot rectangle) ────────────────────────────────────────────────────────────────────
    EchartsDoc("grid.left", """Left inset of the plotting rectangle — px (`60`) or percent (`"8%"`).
        Also `right`/`top`/`bottom`. Grow it to fit long axis names/labels. Slate:
        `echart(:line, x, y; grid=(left=70, right=20))`."""),
    EchartsDoc("grid.containLabel", """`true` makes `grid.left/top/…` measure to the OUTSIDE of the axis
        labels, so nothing clips (recommended with long labels). Default `false`. Slate:
        `grid=(containLabel=true,)`."""),
    EchartsDoc("grid.width", """Explicit plot width (px or `%`); `height` likewise. Usually leave auto
        and set the insets instead. Slate: `grid=(width="60%",)`."""),

    # ── dataZoom (interactive zoom / pan) ────────────────────────────────────────────────────────
    EchartsDoc("dataZoom.type", """Zoom control kind: `"slider"` (a draggable bar below/beside the
        chart) or `"inside"` (scroll/drag inside the plot). Combine both. Slate:
        `echart(:line, x, y; dataZoom=[(type=:slider,), (type=:inside,)])`."""),
    EchartsDoc("dataZoom.start", """Initial zoom window start, `0..100` percent (with `end`). Or use
        `startValue`/`endValue` for data-space bounds. Slate: `dataZoom=[(type=:slider, start=60, end=100)]`."""),
    EchartsDoc("dataZoom.xAxisIndex", """Which axis the zoom acts on (`0`, `1`, or a list). Default: the
        x-axis. Use `yAxisIndex` to zoom values. Slate: `dataZoom=[(type=:inside, yAxisIndex=0)]`."""),

    # ── visualMap (map a data dimension → colour) ────────────────────────────────────────────────
    EchartsDoc("visualMap.type", """`"continuous"` (a gradient bar, default) or `"piecewise"` (discrete
        buckets/legend). Colours points/cells by a data dimension. Slate:
        `echart(:scatter, x, y; visualMap=(min=0, max=1, dimension=1, calculable=true))`."""),
    EchartsDoc("visualMap.min", """Low end of the mapped value range (`max` = high end). Slate:
        `visualMap=(min=0, max=100)`."""),
    EchartsDoc("visualMap.dimension", """Which data dimension drives the colour (`0`=x, `1`=y, `2`=third
        value, …). Slate: `visualMap=(dimension=2, min=0, max=1)`."""),
    EchartsDoc("visualMap.calculable", """`true` shows draggable handles that also filter the data.
        Slate: `visualMap=(calculable=true, min=0, max=1)`. A `:heatmap` adds a visualMap automatically."""),
    EchartsDoc("visualMap.inRange.color", """The colour ramp values map into, e.g.
        `["#313695","#4575b4","#fee090","#a50026"]`. Slate:
        `visualMap=(min=0, max=1, inRange=(color=["#222","#0f0"],))`."""),
    EchartsDoc("visualMap.pieces", """Piecewise buckets: a list like `[(lt=10,), (gte=10, lt=50,), (gte=50,)]`
        with optional `color`/`label`. Requires `type:"piecewise"`. Slate:
        `visualMap=(type=:piecewise, pieces=[(lt=10,), (gte=10,)])`."""),

    # ── legend / tooltip / title ─────────────────────────────────────────────────────────────────
    EchartsDoc("legend", """Series-name legend. Slate auto-adds one when ≥2 series are `name`d; pass a
        spec to place it (`legend=(orient="vertical", left="right")`) or `legend=false` to drop it,
        `legend=true` to force it."""),
    EchartsDoc("legend.orient", """`"horizontal"` (default) or `"vertical"`. Pair with `left/top/right`.
        Slate: `echart(s1, s2; legend=(orient="vertical", right=8, top="middle"))`."""),
    EchartsDoc("legend.selectedMode", """`true` (toggle any), `"single"` (one at a time), or `false`
        (no toggling). Slate: `legend=(selectedMode="single",)`."""),
    EchartsDoc("tooltip.trigger", """`"axis"` (shared crosshair — best for line/bar), `"item"` (per
        point — pie/scatter), or `"none"`. Slate sets a sensible default; override
        `echart(:line, x, y; tooltip=(trigger="axis",))`, or `tooltip=false` to disable."""),
    EchartsDoc("tooltip.formatter", """Tooltip template `"{b}: {c}"` (`{b}`=name, `{c}`=value,
        `{a}`=series) or a JS function string. Slate: `tooltip=(formatter="{b}: {c} kg",)`."""),
    EchartsDoc("tooltip.axisPointer.type", """The indicator drawn with `trigger:"axis"`: `"line"`,
        `"shadow"` (bar band), `"cross"` (both axes), or `"none"`. Slate:
        `tooltip=(trigger="axis", axisPointer=(type="cross",))`."""),
    EchartsDoc("title.text", """Chart title (with optional `subtext`, `left`, `textStyle`). Slate's
        `title="…"` kwarg is shorthand; full control via `title=(text="T", subtext="s", left="center")`."""),

    # ── toolbox (export / built-in tools) ────────────────────────────────────────────────────────
    EchartsDoc("toolbox.feature", """Built-in tool buttons: `saveAsImage`, `dataZoom`, `restore`,
        `dataView`, `magicType` (switch line/bar/stack). Slate:
        `echart(:line, x, y; toolbox=(feature=(saveAsImage=(), dataZoom=(), magicType=(type=["line","bar"],))))`."""),

    # ── series: common props (kwargs on `series(...)` or an Express styling kwarg) ────────────────
    EchartsDoc("series.stack", """Series sharing a `stack` id STACK on top of each other (stacked
        bar/area). Slate: `echart(series(:bar, x, a; stack="t"), series(:bar, x, b; stack="t"))`."""),
    EchartsDoc("series.smooth", """Line smoothing: `true`, or `0..1`. Slate: `echart(:line, x, y; smooth=true)`."""),
    EchartsDoc("series.step", """Step line: `false` (default), `"start"`, `"middle"`, `"end"`. Slate:
        `echart(:line, x, y; step="end")`."""),
    EchartsDoc("series.symbolSize", """Marker size in px (a number) or a function of the datum. Slate:
        `echart(:scatter, x, y; symbolSize=8)` or `symbolSize=d -> d[2]/10`."""),
    EchartsDoc("series.symbol", """Marker shape: `"circle"` (default), `"rect"`, `"triangle"`, `"diamond"`,
        `"none"` (hide), or `"image://url"`. Slate: `echart(:line, x, y; symbol="none")`."""),
    EchartsDoc("series.label", """Per-point value labels: `label=(show=true, position="top",
        formatter="{c}")`. `position`: top/inside/right/… Slate: `echart(:bar, x, y; label=(show=true,))`."""),
    EchartsDoc("series.lineStyle", """Line appearance: `width`, `color`, `type` (`"solid"|"dashed"|"dotted"`),
        `opacity`. Slate: `echart(:line, x, y; lineStyle=(width=3, type="dashed"))`."""),
    EchartsDoc("series.itemStyle", """Point/bar/slice appearance: `color`, `borderColor`, `borderWidth`,
        `borderRadius` (rounded bars), `opacity`. Slate: `echart(:bar, x, y; itemStyle=(borderRadius=4,))`."""),
    EchartsDoc("series.areaStyle", """Fill under a line (turns it into an area). `color`, `opacity`. Slate:
        `echart(:area, x, y)` sets it; or `echart(:line, x, y; areaStyle=(opacity=0.2,))`."""),
    EchartsDoc("series.emphasis", """Hover/focus styling: `emphasis=(focus="series", itemStyle=(…))`.
        `focus="series"` fades other series on hover. Slate: `echart(:line, x, y; emphasis=(focus="series",))`."""),
    EchartsDoc("series.markLine", """Reference lines: `markLine=(data=[(type="average",)])` (or
        `type` min/max), or a fixed value `[(yAxis=100,)]` / `[(xAxis=…,)]`. Slate:
        `echart(:line, x, y; markLine=(data=[(type="average",)],))`."""),
    EchartsDoc("series.markPoint", """Annotated points: `markPoint=(data=[(type="max",), (type="min",)])`
        or explicit coords. Slate: `echart(:line, x, y; markPoint=(data=[(type="max",)],))`."""),
    EchartsDoc("series.markArea", """Shaded region between two bounds: `markArea=(data=[[(xAxis=a,),(xAxis=b,)]])`.
        Slate: `echart(:line, x, y; markArea=(data=[[(xAxis="2020",), (xAxis="2021",)]],))`."""),
    EchartsDoc("series.yAxisIndex", """Bind a series to a SECOND y-axis (`1`) for dual-axis charts (pair
        with an array `yAxis`). `xAxisIndex` likewise. Slate:
        `echart(series(:line,x,a), series(:line,x,b; yAxisIndex=1); yAxis=[(name="L",),(name="R",)])`."""),
    EchartsDoc("series.connectNulls", """Line: `true` bridges `NaN`/missing gaps instead of breaking.
        Slate: `echart(:line, x, y; connectNulls=true)`."""),
    EchartsDoc("series.sampling", """Downsample dense line data for speed: `"lttb"` (keeps shape),
        `"average"`, `"max"`, `"min"`. Slate: `echart(:line, x, y; sampling="lttb")`."""),
    EchartsDoc("series.large", """Scatter perf: `large=true` (+ `largeThreshold`) uses a fast path for
        huge point counts. Slate: `echart(:scatter, x, y; large=true)`."""),

    # ── series: per-kind highlights ──────────────────────────────────────────────────────────────
    EchartsDoc("series.bar.barWidth", """Bar thickness: px or `%` of category slot. Also `barGap`
        (between series) and `barCategoryGap`. Slate: `echart(:bar, x, y; barWidth="50%")`."""),
    EchartsDoc("series.pie.radius", """Pie size: `"70%"`, or `["40%","70%"]` for a donut (inner,outer).
        `center=["50%","50%"]` positions it. Slate: `echart(:pie, labels, vals; radius=["40%","70%"])`."""),
    EchartsDoc("series.pie.roseType", """Nightingale/rose pie: `"radius"` or `"area"` (slice radius
        encodes value). Slate: `echart(:pie, labels, vals; roseType="area")`."""),
    EchartsDoc("series.gauge", """Gauge dial via `series(:gauge; min, max, progress=(show=true,),
        axisLine=(…), data=[(value=v, name="…")])`. Slate:
        `echart(series(:gauge; min=0, max=100, data=[(value=72,)]))`."""),
    EchartsDoc("series.funnel", """Funnel via `series(:funnel; sort="descending", min, max,
        data=[(value=100, name="Visits"), …])`. Slate: `echart(series(:funnel; data=[…]))`."""),
    EchartsDoc("series.candlestick", """OHLC: each datum `[open, close, low, high]`. Slate ergonomic
        form: `echart(:candlestick, dates, ohlc)` where `ohlc[i]=[open,close,low,high]`."""),
    EchartsDoc("series.boxplot", """Box plot: each datum `[min, Q1, median, Q3, max]`. Slate:
        `echart(:boxplot, categories, data)` — pass 5-number arrays OR raw samples (auto-summarised)."""),
    EchartsDoc("series.sankey", """Sankey flow diagram: nodes + weighted links. Slate ergonomic form:
        `echart(:sankey, [(source, target, value), …])` (nodes auto-derived) or `echart(:sankey, nodes, links)`;
        a link may also be `src => tgt => val`. Style via `nodeGap`, `nodeWidth`, `lineStyle=(color="gradient",)`."""),
    EchartsDoc("series.graph", """Network/graph: nodes + edges, force-directed + roamable by default. Slate:
        `echart(:graph, [(source, target), …])` (nodes auto-derived) or `echart(:graph, nodes, edges)`; an edge
        may be `src => tgt`. Override `layout="circular"|"none"`, `force=(repulsion=…, edgeLength=…)`, node `symbolSize`."""),
    EchartsDoc("series.treemap", """Treemap hierarchy. Slate: `echart(:treemap, tree)` where a node is
        `name => value` (leaf), `name => [children…]` (branch), or a NamedTuple/Dict; one root or a vector of roots.
        `:sunburst` takes the SAME data shape (radial hierarchy). Style via `levels`, `visibleMin`, `leafDepth`."""),
    EchartsDoc("series.lines.geo", """Geo trajectories/flows: `type="lines"`, `coordinateSystem="geo"`, each
        datum `{coords:[[lon,lat],[lon,lat]]}`. Slate: `echart(:lines, from, to; geo=(map="world",…), registerMap=…)`
        — coords are `(lon,lat)`. Add `effect=(show=true, symbol="arrow")` for animated flow; `lineStyle=(curveness=0.2,)`."""),
    EchartsDoc("series.calendar", """Calendar heatmap: a heatmap series on `coordinateSystem="calendar"`, each
        datum `[date, value]`, plus a `calendar` component (range) + `visualMap`. Slate: `echart(:calendar, dates, values)`
        — dates are `Date`s or `"YYYY-MM-DD"`; the year range is auto-spanned. Style the `calendar=(cellSize=…, …)`."""),

    # ── whole-chart ──────────────────────────────────────────────────────────────────────────────
    EchartsDoc("color", """The series colour cycle: a list of colours applied in order. Slate:
        `echart(:line, x, y; color=["#56d364","#f78166"])`."""),
    EchartsDoc("backgroundColor", """Canvas background. Slate defaults it TRANSPARENT (dark theme);
        set a colour with `echart(:line, x, y; backgroundColor="#0d1117")` or opt out via `theme=false`."""),
    EchartsDoc("animationDurationUpdate", """Transition (ms) when a chart re-`setOption`s on a reactive
        update. Slate defaults ≈300 (snappier than ECharts' 1000 for live streams); `animation=false`
        snaps instantly. Slate: `echart(:line, x, y; animationDurationUpdate=0)`."""),
]

# Records for the semantic index — module "ECharts", so module-scoped search includes them alongside
# the Slate helpers and the notebook's packages.
echarts_doc_records() = [Dict{String,Any}("module" => "ECharts", "name" => e.path, "doc" => e.doc)
                         for e in ECHARTS_OPTION_DOCS]

# Content hash so the auto-indexer re-indexes only when these docs actually change.
echarts_docs_version() = string(hash(echarts_doc_records()); base = 16)

# Look up ONE ECharts option by exact path (case-insensitive) — the docs UI resolves an "ECharts.<path>"
# drill-down from THIS registry. Returns the entry or `nothing`.
function echarts_doc_entry(path::AbstractString)
    p = lowercase(strip(String(path)))
    isempty(p) && return nothing
    for e in ECHARTS_OPTION_DOCS
        lowercase(e.path) == p && return e
    end
    return nothing
end
